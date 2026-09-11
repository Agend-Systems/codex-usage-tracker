import Darwin
import Foundation

struct JSONLBuffer {
  private(set) var data = Data()

  mutating func append(_ chunk: Data) -> [Data] {
    data.append(chunk)
    var lines: [Data] = []
    while let newline = data.firstIndex(of: 0x0A) {
      let line = Data(data[..<newline])
      data.removeSubrange(...newline)
      if !line.isEmpty { lines.append(line) }
    }
    return lines
  }

  mutating func removeAll() {
    data.removeAll(keepingCapacity: true)
  }
}

final class ChildProcessRegistry: @unchecked Sendable {
  static let shared = ChildProcessRegistry()

  private let lock = NSLock()
  private var processes: [ObjectIdentifier: Process] = [:]

  private init() {}

  func register(_ process: Process) {
    lock.lock()
    processes[ObjectIdentifier(process)] = process
    lock.unlock()
  }

  func unregister(_ process: Process) {
    lock.lock()
    processes.removeValue(forKey: ObjectIdentifier(process))
    lock.unlock()
  }

  func terminateAllSynchronously() {
    lock.lock()
    let running = Array(processes.values)
    processes.removeAll()
    lock.unlock()

    for process in running where process.isRunning { process.terminate() }
    let deadline = Date().addingTimeInterval(2)
    while running.contains(where: \.isRunning), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    for process in running where process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }
}

actor CodexAppServerClient {
  private enum CodexHomeSelection: Equatable {
    case inheritedDefault
    case path(String)

    init(_ normalizedPath: String?) {
      self = normalizedPath.map(Self.path) ?? .inheritedDefault
    }

    var displayPath: String {
      switch self {
      case .inheritedDefault: return "default Codex home"
      case .path(let path): return path
      }
    }
  }

  private struct PendingRequest {
    var continuation: CheckedContinuation<Data, Error>
    var timeoutTask: Task<Void, Never>
  }

  private struct RPCRequest<Params: Encodable>: Encodable {
    var method: String
    var id: Int?
    var params: Params
  }

  private struct RPCError: Decodable {
    var code: Int
    var message: String
  }

  private struct RPCResponse<Result: Decodable>: Decodable {
    var id: Int
    var result: Result?
    var error: RPCError?
  }

  private struct EmptyParams: Codable {}
  private struct InitializeParams: Encodable {
    struct ClientInfo: Encodable {
      var name = "codex_usage_tracker"
      var title = "Codex Usage Tracker"
      var version: String
    }
    var clientInfo: ClientInfo
  }

  private struct InitializeResult: Decodable {
    var userAgent: String?
    var codexHome: String?
    var platformFamily: String?
    var platformOs: String?
  }

  struct AccountReadResponse: Decodable {
    var account: CodexAccount?
    var requiresOpenaiAuth: Bool
  }

  private struct AccountReadParams: Encodable {
    var refreshToken: Bool
  }

  private struct RateLimitsNotification: Decodable {
    var rateLimits: RateLimitBucket
  }

  private struct NotificationEnvelope<Params: Decodable>: Decodable {
    var method: String
    var params: Params
  }

  private struct ConsumeResetParams: Encodable {
    var idempotencyKey: String
    var creditId: String?
  }

  struct ConsumeResetResponse: Decodable {
    var outcome: String
  }

  private var process: Process?
  private var processIdentity: ObjectIdentifier?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var outputContinuation: AsyncStream<Data>.Continuation?
  private var errorContinuation: AsyncStream<Data>.Continuation?
  private var outputReaderTask: Task<Void, Never>?
  private var errorReaderTask: Task<Void, Never>?
  private var outputBuffer = JSONLBuffer()
  private var errorBuffer = Data()
  private var pending: [Int: PendingRequest] = [:]
  private var nextID = 1
  private var intentionallyStopping = false
  private var isInitialized = false
  private var startTask: Task<Void, Error>?
  private var startGeneration = 0
  private var startingHome: CodexHomeSelection?
  private var connectedHome: CodexHomeSelection?
  private var rateLimitHandler: (@Sendable (RateLimitBucket) -> Void)?

  func setRateLimitHandler(_ handler: (@Sendable (RateLimitBucket) -> Void)?) {
    rateLimitHandler = handler
  }

  func start(codexHome: String?) async throws {
    let requestedHome = CodexHomeSelection(Self.normalizedCodexHome(codexHome))
    if let startTask {
      guard homesMatch(startingHome, requestedHome) else {
        throw CodexTrackerError.codexHomeMismatch(
          expected: requestedHome.displayPath,
          actual: startingHome?.displayPath ?? "another Codex home")
      }
      try await startTask.value
      return
    }
    if process?.isRunning == true, isInitialized {
      guard homesMatch(connectedHome, requestedHome) else {
        throw CodexTrackerError.codexHomeMismatch(
          expected: requestedHome.displayPath,
          actual: connectedHome?.displayPath ?? "another Codex home")
      }
      return
    }

    startGeneration += 1
    let generation = startGeneration
    startingHome = requestedHome
    let task = Task { try await self.performStart(codexHome: codexHome) }
    startTask = task
    do {
      try await task.value
      if startGeneration == generation {
        connectedHome = requestedHome
        startingHome = nil
        startTask = nil
      }
    } catch {
      if startGeneration == generation {
        startingHome = nil
        startTask = nil
      }
      throw error
    }
  }

  private func homesMatch(
    _ current: CodexHomeSelection?, _ requested: CodexHomeSelection
  ) -> Bool {
    guard let current else { return false }
    switch (current, requested) {
    case (.inheritedDefault, .inheritedDefault):
      return true
    case (.path(let currentPath), .path(let requestedPath)):
      return Self.sameDirectory(currentPath, requestedPath)
    default:
      return false
    }
  }

  private func performStart(codexHome: String?) async throws {
    guard let executable = Self.resolveCodexExecutable() else {
      throw CodexTrackerError.executableNotFound
    }

    intentionallyStopping = false
    isInitialized = false
    outputBuffer.removeAll()
    errorBuffer.removeAll(keepingCapacity: true)

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    let (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
    let (errorStream, errorContinuation) = AsyncStream<Data>.makeStream()
    process.executableURL = executable
    process.arguments = ["app-server", "--stdio"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    var environment = Self.processEnvironment(for: executable)
    let requestedHome = Self.normalizedCodexHome(codexHome)
    if let requestedHome { environment["CODEX_HOME"] = requestedHome }
    process.environment = environment

    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        outputContinuation.finish()
        return
      }
      outputContinuation.yield(data)
    }
    errors.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        errorContinuation.finish()
        return
      }
      errorContinuation.yield(data)
    }
    process.terminationHandler = { [weak self] terminatedProcess in
      ChildProcessRegistry.shared.unregister(terminatedProcess)
      let identity = ObjectIdentifier(terminatedProcess)
      Task {
        await self?.processTerminated(
          identity: identity, status: terminatedProcess.terminationStatus)
      }
    }

    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      errors.fileHandleForReading.readabilityHandler = nil
      outputContinuation.finish()
      errorContinuation.finish()
      throw error
    }

    ChildProcessRegistry.shared.register(process)
    self.process = process
    processIdentity = ObjectIdentifier(process)
    inputPipe = input
    outputPipe = output
    errorPipe = errors
    self.outputContinuation = outputContinuation
    self.errorContinuation = errorContinuation
    outputReaderTask = Task { [weak self] in
      for await chunk in outputStream { await self?.receiveOutput(chunk) }
    }
    errorReaderTask = Task { [weak self] in
      for await chunk in errorStream { await self?.receiveError(chunk) }
    }

    do {
      let version =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
      let result: InitializeResult = try await request(
        method: "initialize",
        params: InitializeParams(clientInfo: .init(version: version))
      )
      if let requestedHome {
        guard let actualHome = result.codexHome,
          Self.sameDirectory(requestedHome, actualHome)
        else {
          throw CodexTrackerError.codexHomeMismatch(
            expected: requestedHome, actual: result.codexHome ?? "not reported")
        }
      }
      try sendNotification(method: "initialized", params: EmptyParams())
      isInitialized = true
    } catch {
      tearDownConnection(error: error, terminate: true)
      throw error
    }
  }

  func stop() {
    intentionallyStopping = true
    startGeneration += 1
    startingHome = nil
    startTask?.cancel()
    startTask = nil
    tearDownConnection(
      error: CodexTrackerError.serverExited("Connection closed"), terminate: true)
  }

  func readAccount(refreshToken: Bool = false) async throws -> AccountReadResponse {
    let response: AccountReadResponse = try await request(
      method: "account/read",
      params: AccountReadParams(refreshToken: refreshToken)
    )
    if response.requiresOpenaiAuth && response.account == nil {
      throw CodexTrackerError.notAuthenticated
    }
    return response
  }

  func readRateLimits() async throws -> RateLimitsResponse {
    do {
      return try await request(method: "account/rateLimits/read", params: EmptyParams())
    } catch let CodexTrackerError.rpc(code, _) where code == -32601 {
      throw CodexTrackerError.incompatibleCLI
    }
  }

  func readTokenUsage() async throws -> TokenUsageResponse {
    do {
      return try await request(method: "account/usage/read", params: EmptyParams())
    } catch let CodexTrackerError.rpc(code, _) where code == -32601 {
      throw CodexTrackerError.incompatibleCLI
    }
  }

  func consumeResetCredit(id: String?, idempotencyKey: String) async throws
    -> ConsumeResetResponse
  {
    try await request(
      method: "account/rateLimitResetCredit/consume",
      params: ConsumeResetParams(idempotencyKey: idempotencyKey, creditId: id)
    )
  }

  private func request<Result: Decodable, Params: Encodable>(method: String, params: Params)
    async throws -> Result
  {
    guard process?.isRunning == true, isInitialized || method == "initialize" else {
      throw CodexTrackerError.serverExited("Not running")
    }
    let id = nextID
    nextID += 1
    let message = RPCRequest(method: method, id: id, params: params)
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)

    let responseData: Data
    do {
      responseData = try await awaitResponse(id: id, method: method, writing: data)
    } catch {
      if let trackerError = error as? CodexTrackerError,
        case .requestTimedOut = trackerError
      {
        tearDownConnection(error: error, terminate: true)
      }
      throw error
    }

    guard let envelope = try? JSONDecoder().decode(RPCResponse<Result>.self, from: responseData)
    else {
      throw CodexTrackerError.malformedResponse
    }
    if let error = envelope.error {
      throw CodexTrackerError.rpc(code: error.code, message: error.message)
    }
    guard let result = envelope.result else { throw CodexTrackerError.malformedResponse }
    return result
  }

  private func awaitResponse(id: Int, method: String, writing data: Data) async throws -> Data {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
          return
        }
        let timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: .seconds(20))
          } catch {
            return
          }
          await self?.timeoutPendingRequest(id: id, method: method)
        }
        pending[id] = PendingRequest(
          continuation: continuation,
          timeoutTask: timeoutTask)
        do {
          guard let writer = inputPipe?.fileHandleForWriting else {
            throw CodexTrackerError.serverExited("Input pipe is unavailable")
          }
          try writer.write(contentsOf: data)
        } catch {
          pending.removeValue(forKey: id)?.timeoutTask.cancel()
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Task { await self.cancelPendingRequest(id: id) }
    }
  }

  private func cancelPendingRequest(id: Int) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    request.continuation.resume(throwing: CancellationError())
  }

  private func timeoutPendingRequest(id: Int, method: String) {
    guard let request = pending.removeValue(forKey: id) else { return }
    request.continuation.resume(throwing: CodexTrackerError.requestTimedOut(method))
  }

  private func sendNotification<Params: Encodable>(method: String, params: Params) throws {
    let message = RPCRequest(method: method, id: nil, params: params)
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    guard let writer = inputPipe?.fileHandleForWriting else {
      throw CodexTrackerError.serverExited("Input pipe is unavailable")
    }
    try writer.write(contentsOf: data)
  }

  private func receiveOutput(_ data: Data) {
    for line in outputBuffer.append(data) { route(line) }
  }

  private func receiveError(_ data: Data) {
    errorBuffer.append(data)
    if errorBuffer.count > 8_192 { errorBuffer = Data(errorBuffer.suffix(8_192)) }
  }

  private func route(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }
    if Self.isResponse(object), let id = object["id"] as? Int,
      let request = pending.removeValue(forKey: id)
    {
      request.timeoutTask.cancel()
      request.continuation.resume(returning: line)
      return
    }
    guard object["method"] as? String == "account/rateLimits/updated",
      let notification = try? JSONDecoder().decode(
        NotificationEnvelope<RateLimitsNotification>.self, from: line)
    else {
      return
    }
    rateLimitHandler?(notification.params.rateLimits)
  }

  nonisolated static func isResponse(_ object: [String: Any]) -> Bool {
    object["method"] == nil && (object["result"] != nil || object["error"] != nil)
  }

  private func processTerminated(identity: ObjectIdentifier, status: Int32) {
    guard processIdentity == identity else { return }
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    outputContinuation?.finish()
    errorContinuation?.finish()
    outputReaderTask?.cancel()
    errorReaderTask?.cancel()

    guard !intentionallyStopping else {
      clearConnectionReferences()
      return
    }
    let detail =
      String(data: errorBuffer, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(status)"
    failPending(with: CodexTrackerError.serverExited(detail))
    clearConnectionReferences()
  }

  private func tearDownConnection(error: Error, terminate: Bool) {
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    outputContinuation?.finish()
    errorContinuation?.finish()
    outputReaderTask?.cancel()
    errorReaderTask?.cancel()
    inputPipe?.fileHandleForWriting.closeFile()
    if terminate, process?.isRunning == true { process?.terminate() }
    failPending(with: error)
    clearConnectionReferences()
  }

  private func clearConnectionReferences() {
    isInitialized = false
    connectedHome = nil
    process = nil
    processIdentity = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    outputContinuation = nil
    errorContinuation = nil
    outputReaderTask = nil
    errorReaderTask = nil
  }

  private func failPending(with error: Error) {
    let requests = pending.values
    pending.removeAll()
    for request in requests {
      request.timeoutTask.cancel()
      request.continuation.resume(throwing: error)
    }
  }

  nonisolated static func resolveCodexExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var candidates = [
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
      home + "/.local/bin/codex",
      home + "/.npm-global/bin/codex",
      home + "/.bun/bin/codex",
      home + "/.volta/bin/codex",
      home + "/.local/share/mise/shims/codex",
      home + "/.asdf/shims/codex",
    ]
    let nvmRoot = URL(fileURLWithPath: home + "/.nvm/versions/node", isDirectory: true)
    if let versions = try? FileManager.default.contentsOfDirectory(
      at: nvmRoot, includingPropertiesForKeys: nil)
    {
      candidates +=
        versions.sorted {
          Self.nvmVersionIsNewer($0.lastPathComponent, than: $1.lastPathComponent)
        }.map { $0.appendingPathComponent("bin/codex").path }
    }
    if let path = environment["PATH"] {
      candidates += path.split(separator: ":").map { String($0) + "/codex" }
    }
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  nonisolated static func processEnvironment(
    for executable: URL,
    inheriting environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    var environment = environment
    let executableDirectory = executable.deletingLastPathComponent().path
    let inheritedDirectories =
      environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let searchDirectories =
      [executableDirectory] + inheritedDirectories.filter { $0 != executableDirectory }
    environment["PATH"] = searchDirectories.joined(separator: ":")
    return environment
  }

  nonisolated static func normalizedCodexHome(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return standardizedPath((value as NSString).expandingTildeInPath)
  }

  nonisolated static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
    let left = URL(fileURLWithPath: lhs)
    let right = URL(fileURLWithPath: rhs)
    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    if let leftValues = try? left.resourceValues(forKeys: keys),
      let rightValues = try? right.resourceValues(forKeys: keys),
      let leftIdentifier = leftValues.fileResourceIdentifier,
      let rightIdentifier = rightValues.fileResourceIdentifier
    {
      return leftIdentifier.isEqual(rightIdentifier)
    }
    return standardizedPath(lhs).compare(
      standardizedPath(rhs), options: .caseInsensitive) == .orderedSame
  }

  nonisolated static func nvmVersionIsNewer(_ lhs: String, than rhs: String) -> Bool {
    lhs.compare(rhs, options: .numeric) == .orderedDescending
  }

  nonisolated private static func standardizedPath(_ value: String) -> String {
    URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
  }
}
