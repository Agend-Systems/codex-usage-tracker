import Foundation

actor CodexAppServerClient {
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
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var outputBuffer = Data()
  private var errorBuffer = Data()
  private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
  private var nextID = 1
  private var intentionallyStopping = false
  private var rateLimitHandler: (@Sendable (RateLimitBucket) -> Void)?

  func setRateLimitHandler(_ handler: (@Sendable (RateLimitBucket) -> Void)?) {
    rateLimitHandler = handler
  }

  func start(codexHome: String?) async throws {
    if process?.isRunning == true { return }
    guard let executable = Self.resolveCodexExecutable() else {
      throw CodexTrackerError.executableNotFound
    }

    intentionallyStopping = false
    outputBuffer.removeAll(keepingCapacity: true)
    errorBuffer.removeAll(keepingCapacity: true)

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executable
    process.arguments = ["app-server", "--stdio"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    var environment = ProcessInfo.processInfo.environment
    if let codexHome = codexHome?.trimmingCharacters(in: .whitespacesAndNewlines),
      !codexHome.isEmpty
    {
      environment["CODEX_HOME"] = (codexHome as NSString).expandingTildeInPath
    }
    process.environment = environment

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { await self?.receiveOutput(data) }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task { await self?.receiveError(data) }
    }
    process.terminationHandler = { [weak self] process in
      Task { await self?.processTerminated(status: process.terminationStatus) }
    }

    try process.run()
    self.process = process
    inputPipe = input
    outputPipe = output
    errorPipe = errors

    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let _: InitializeResult = try await request(
      method: "initialize",
      params: InitializeParams(clientInfo: .init(version: version))
    )
    try sendNotification(method: "initialized", params: EmptyParams())
  }

  func stop() {
    intentionallyStopping = true
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    inputPipe?.fileHandleForWriting.closeFile()
    if process?.isRunning == true { process?.terminate() }
    failPending(with: CodexTrackerError.serverExited("Connection closed"))
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
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

  func consumeResetCredit(id: String?) async throws -> ConsumeResetResponse {
    try await request(
      method: "account/rateLimitResetCredit/consume",
      params: ConsumeResetParams(idempotencyKey: UUID().uuidString, creditId: id)
    )
  }

  private func request<Result: Decodable, Params: Encodable>(method: String, params: Params)
    async throws -> Result
  {
    guard process?.isRunning == true else {
      throw CodexTrackerError.serverExited("Not running")
    }
    let id = nextID
    nextID += 1
    let message = RPCRequest(method: method, id: id, params: params)
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)

    let responseData: Data = try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      do {
        try inputPipe?.fileHandleForWriting.write(contentsOf: data)
      } catch {
        pending.removeValue(forKey: id)
        continuation.resume(throwing: error)
      }
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

  private func sendNotification<Params: Encodable>(method: String, params: Params) throws {
    let message = RPCRequest(method: method, id: nil, params: params)
    var data = try JSONEncoder().encode(message)
    data.append(0x0A)
    try inputPipe?.fileHandleForWriting.write(contentsOf: data)
  }

  private func receiveOutput(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = Data(outputBuffer[..<newline])
      outputBuffer.removeSubrange(...newline)
      guard !line.isEmpty else { continue }
      route(line)
    }
  }

  private func receiveError(_ data: Data) {
    errorBuffer.append(data)
    if errorBuffer.count > 8_192 {
      errorBuffer = Data(errorBuffer.suffix(8_192))
    }
  }

  private func route(_ line: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
      return
    }
    if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
      continuation.resume(returning: line)
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

  private func processTerminated(status: Int32) {
    guard !intentionallyStopping else { return }
    let detail =
      String(data: errorBuffer, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(status)"
    failPending(with: CodexTrackerError.serverExited(detail))
    process = nil
  }

  private func failPending(with error: Error) {
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }

  nonisolated static func resolveCodexExecutable(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    var candidates: [String] = []
    if let path = environment["PATH"] {
      candidates += path.split(separator: ":").map { String($0) + "/codex" }
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    candidates += [
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      home + "/.local/bin/codex",
      home + "/.npm-global/bin/codex",
      "/Applications/Codex.app/Contents/Resources/codex",
    ]
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return nil }
    return URL(fileURLWithPath: path)
  }
}
