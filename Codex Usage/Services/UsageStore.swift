import Combine
import Foundation
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
  static let shared = UsageStore()

  @Published private(set) var snapshots: [UUID: UsageSnapshot] = [:]
  @Published private(set) var states: [UUID: ConnectionState] = [:]
  @Published private(set) var serviceStatus = "Checking OpenAI status…"
  @Published private(set) var isRefreshing = false
  @Published private(set) var redeemingProfiles: Set<UUID> = []

  private let preferences = TrackerPreferences.shared
  private let history = HistoryStore.shared
  private var clients: [UUID: CodexAppServerClient] = [:]
  private var clientHomes: [UUID: String] = [:]
  private var refreshTasks: [UUID: Task<Void, Never>] = [:]
  private var refreshAllTask: Task<Void, Never>?
  private var refreshLoop: Task<Void, Never>?
  private var refreshActivityCount = 0
  private var lastScheduledRefresh: [UUID: Date] = [:]
  private var notifiedThresholds: Set<String> = []

  private init() {
    if let data = UserDefaults.standard.data(forKey: "tracker.snapshots.v1"),
      let cache = try? JSONDecoder().decode([UUID: UsageSnapshot].self, from: data)
    {
      snapshots = cache
    }
  }

  var activeSnapshot: UsageSnapshot? { snapshots[preferences.activeProfileID] }
  var activeState: ConnectionState { states[preferences.activeProfileID] ?? .idle }

  func start() {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    refreshLoop?.cancel()
    refreshLoop = Task { [weak self] in
      guard let self else { return }
      await self.refreshAll()
      while !Task.isCancelled {
        let interval = max(30, self.preferences.refreshInterval)
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled else { return }
        await self.refreshAll()
      }
    }
  }

  func stop() async {
    refreshLoop?.cancel()
    refreshLoop = nil
    refreshAllTask?.cancel()
    refreshAllTask = nil
    for task in refreshTasks.values { task.cancel() }
    refreshTasks.removeAll()
    let currentClients = Array(clients.values)
    clients.removeAll()
    clientHomes.removeAll()
    await withTaskGroup(of: Void.self) { group in
      for client in currentClients {
        group.addTask { await client.stop() }
      }
    }
  }

  nonisolated static func terminateChildrenSynchronously() {
    ChildProcessRegistry.shared.terminateAllSynchronously()
  }

  func refreshAll() async {
    if let refreshAllTask {
      await refreshAllTask.value
      return
    }
    beginRefreshActivity()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performRefreshAll()
    }
    refreshAllTask = task
    await task.value
    refreshAllTask = nil
    endRefreshActivity()
  }

  func refreshProfile(_ profile: CodexProfile) async {
    beginRefreshActivity()
    await refresh(profile)
    endRefreshActivity()
  }

  func refresh(_ profile: CodexProfile) async {
    if let task = refreshTasks[profile.id] {
      await task.value
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performRefresh(profile)
    }
    refreshTasks[profile.id] = task
    await task.value
    refreshTasks.removeValue(forKey: profile.id)
  }

  func reconnect(_ profile: CodexProfile) async {
    if let task = refreshTasks[profile.id] {
      task.cancel()
      await task.value
      refreshTasks.removeValue(forKey: profile.id)
    }
    if let client = clients.removeValue(forKey: profile.id) { await client.stop() }
    clientHomes.removeValue(forKey: profile.id)
    await refreshProfile(profile)
  }

  func remove(_ profile: CodexProfile) async {
    if let task = refreshTasks.removeValue(forKey: profile.id) {
      task.cancel()
      await task.value
    }
    if let client = clients.removeValue(forKey: profile.id) { await client.stop() }
    clientHomes.removeValue(forKey: profile.id)
    lastScheduledRefresh.removeValue(forKey: profile.id)
    snapshots.removeValue(forKey: profile.id)
    states.removeValue(forKey: profile.id)
    history.delete(profileID: profile.id)
    preferences.clearResetCreditIdempotencyKeys(profileID: profile.id)
    saveCache()
  }

  func redeem(_ credit: ResetCredit, for profile: CodexProfile) async throws -> String {
    guard !redeemingProfiles.contains(profile.id) else {
      throw CodexTrackerError.redemptionInProgress
    }
    redeemingProfiles.insert(profile.id)
    defer { redeemingProfiles.remove(profile.id) }

    if let task = refreshTasks[profile.id] { await task.value }
    let client = await client(for: profile)
    try await client.start(codexHome: profile.codexHome)
    let key = preferences.resetCreditIdempotencyKey(
      profileID: profile.id, creditID: credit.id)
    let result = try await client.consumeResetCredit(id: credit.id, idempotencyKey: key)
    preferences.clearResetCreditIdempotencyKey(profileID: profile.id, creditID: credit.id)
    await refresh(profile)
    switch result.outcome {
    case "reset": return "Usage window reset"
    case "nothingToReset": return "No window is eligible yet"
    case "noCredit": return "No reset credit available"
    case "alreadyRedeemed": return "Reset already applied"
    default: return result.outcome
    }
  }

  func clearCachedData() {
    refreshAllTask?.cancel()
    refreshAllTask = nil
    for task in refreshTasks.values { task.cancel() }
    refreshTasks.removeAll()
    let currentClients = Array(clients.values)
    clients.removeAll()
    clientHomes.removeAll()
    lastScheduledRefresh.removeAll()
    snapshots.removeAll()
    states.removeAll()
    refreshActivityCount = 0
    isRefreshing = false
    notifiedThresholds.removeAll()
    UserDefaults.standard.removeObject(forKey: "tracker.snapshots.v1")
    history.deleteAll()
    preferences.clearAllResetCreditIdempotencyKeys()
    Task {
      await withTaskGroup(of: Void.self) { group in
        for client in currentClients {
          group.addTask { await client.stop() }
        }
      }
    }
  }

  nonisolated static func merged(
    old: RateLimitBucket?, new: RateLimitBucket
  ) -> RateLimitBucket {
    guard let old else { return new }
    return RateLimitBucket(
      limitId: new.limitId ?? old.limitId,
      limitName: new.limitName ?? old.limitName,
      planType: new.planType ?? old.planType,
      primary: new.primary ?? old.primary,
      secondary: new.secondary ?? old.secondary,
      credits: new.credits ?? old.credits,
      individualLimit: new.individualLimit ?? old.individualLimit,
      rateLimitReachedType: new.rateLimitReachedType ?? old.rateLimitReachedType,
      spendControlReached: new.spendControlReached ?? old.spendControlReached
    )
  }

  nonisolated static func mergingLiveBucket(
    _ bucket: RateLimitBucket, into cached: RateLimitsResponse
  ) -> RateLimitsResponse? {
    var response = cached
    var didMerge = false
    if var buckets = response.rateLimitsByLimitId {
      let matchingKey = buckets.keys.first { key in
        key == bucket.limitId
          || buckets[key]?.limitId == bucket.limitId
          || (bucket.limitId == nil && bucket.limitName != nil
            && buckets[key]?.limitName == bucket.limitName)
      }
      if let matchingKey {
        buckets[matchingKey] = merged(old: buckets[matchingKey], new: bucket)
        response.rateLimitsByLimitId = buckets
        didMerge = true
      }
    }
    let primaryMatches =
      (bucket.limitId != nil && response.rateLimits.limitId == bucket.limitId)
      || (bucket.limitName != nil && response.rateLimits.limitName == bucket.limitName)
      || (response.rateLimitsByLimitId?.isEmpty != false
        && response.rateLimits.id == bucket.id)
    if primaryMatches {
      response.rateLimits = merged(old: response.rateLimits, new: bucket)
      didMerge = true
    }
    return didMerge ? response : nil
  }

  private func performRefreshAll() async {
    async let status: Void = refreshServiceStatus()
    let profiles = preferences.profiles.filter {
      $0.isVisible || $0.id == preferences.activeProfileID
    }
    await withTaskGroup(of: Void.self) { group in
      for profile in profiles {
        group.addTask { await self.refresh(profile) }
      }
    }
    await status
  }

  private func performRefresh(_ profile: CodexProfile) async {
    states[profile.id] = .connecting
    let client = await client(for: profile)
    let profileID = profile.id
    await client.setRateLimitHandler { bucket in
      Task { @MainActor in UsageStore.shared.mergeLiveBucket(bucket, profileID: profileID) }
    }

    do {
      try await client.start(codexHome: profile.codexHome)
      async let accountResponse = client.readAccount()
      async let limitsResponse = client.readRateLimits()
      async let tokenUsageResponse = try? client.readTokenUsage()
      let (account, limits, tokenUsage) = try await (
        accountResponse, limitsResponse, tokenUsageResponse
      )
      let snapshot = UsageSnapshot(
        account: account.account,
        limits: limits,
        tokenUsage: tokenUsage,
        fetchedAt: Date()
      )
      snapshots[profile.id] = snapshot
      states[profile.id] = .connected
      history.record(profileID: profile.id, response: limits)
      saveCache()
      checkNotifications(profile: profile, limits: limits)
    } catch is CancellationError {
      states[profile.id] = .idle
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  private func client(for profile: CodexProfile) async -> CodexAppServerClient {
    let normalizedHome = CodexAppServerClient.normalizedCodexHome(profile.codexHome) ?? ""
    if clientHomes[profile.id] != normalizedHome,
      let staleClient = clients.removeValue(forKey: profile.id)
    {
      await staleClient.stop()
    }
    let client = clients[profile.id] ?? CodexAppServerClient()
    clients[profile.id] = client
    clientHomes[profile.id] = normalizedHome
    return client
  }

  private func mergeLiveBucket(_ bucket: RateLimitBucket, profileID: UUID) {
    guard var snapshot = snapshots[profileID], let response = snapshot.limits else {
      scheduleRefresh(profileID: profileID)
      return
    }

    guard let mergedResponse = Self.mergingLiveBucket(bucket, into: response) else {
      scheduleRefresh(profileID: profileID)
      return
    }

    snapshot.limits = mergedResponse
    snapshot.fetchedAt = Date()
    snapshots[profileID] = snapshot
    saveCache()
  }

  private func scheduleRefresh(profileID: UUID) {
    let now = Date()
    if let lastRefresh = lastScheduledRefresh[profileID],
      now.timeIntervalSince(lastRefresh) < 30
    {
      return
    }
    lastScheduledRefresh[profileID] = now
    guard let profile = preferences.profiles.first(where: { $0.id == profileID }) else { return }
    Task { await refreshProfile(profile) }
  }

  private func beginRefreshActivity() {
    refreshActivityCount += 1
    isRefreshing = true
  }

  private func endRefreshActivity() {
    refreshActivityCount = max(0, refreshActivityCount - 1)
    isRefreshing = refreshActivityCount > 0
  }

  private func saveCache() {
    if let data = try? JSONEncoder().encode(snapshots) {
      UserDefaults.standard.set(data, forKey: "tracker.snapshots.v1")
    }
  }

  private func checkNotifications(profile: CodexProfile, limits: RateLimitsResponse) {
    for bucket in limits.buckets {
      for (windowName, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
        guard let window else { continue }
        let threshold =
          window.usedPercent >= preferences.criticalThreshold
          ? preferences.criticalThreshold
          : window.usedPercent >= preferences.warningThreshold ? preferences.warningThreshold : nil
        let key = "\(profile.id)-\(bucket.id)-\(windowName)"
        if let threshold, !notifiedThresholds.contains("\(key)-\(threshold)") {
          let content = UNMutableNotificationContent()
          content.title = "Codex usage at \(Int(window.usedPercent))%"
          content.body = "\(profile.name) · \(bucket.displayName) · \(window.durationLabel)"
          content.sound = .default
          UNUserNotificationCenter.current().add(
            .init(identifier: UUID().uuidString, content: content, trigger: nil))
          notifiedThresholds.insert("\(key)-\(threshold)")
        }
        if window.usedPercent < preferences.warningThreshold {
          notifiedThresholds = Set(notifiedThresholds.filter { !$0.hasPrefix(key) })
        }
      }
    }
  }

  private func refreshServiceStatus() async {
    guard let url = URL(string: "https://status.openai.com/api/v2/status.json") else { return }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      let (data, _) = try await session.data(from: url)
      struct Response: Decodable {
        struct Status: Decodable {
          var indicator: String
          var description: String
        }
        var status: Status
      }
      let response = try JSONDecoder().decode(Response.self, from: data)
      serviceStatus =
        response.status.indicator == "none"
        ? "All systems operational" : response.status.description
    } catch {
      serviceStatus = "OpenAI status unavailable"
    }
  }
}
