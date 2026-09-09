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

  private let preferences = TrackerPreferences.shared
  private let history = HistoryStore.shared
  private var clients: [UUID: CodexAppServerClient] = [:]
  private var clientHomes: [UUID: String] = [:]
  private var refreshLoop: Task<Void, Never>?
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

  func stop() {
    refreshLoop?.cancel()
    refreshLoop = nil
    let currentClients = clients.values
    clients.removeAll()
    clientHomes.removeAll()
    for client in currentClients { Task { await client.stop() } }
  }

  func refreshAll() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    await refreshServiceStatus()
    for profile in preferences.profiles
    where profile.isVisible || profile.id == preferences.activeProfileID {
      await refresh(profile)
    }
  }

  func refresh(_ profile: CodexProfile) async {
    states[profile.id] = .connecting
    let normalizedHome = profile.codexHome.map { ($0 as NSString).expandingTildeInPath } ?? ""
    if clientHomes[profile.id] != normalizedHome,
      let staleClient = clients.removeValue(forKey: profile.id)
    {
      await staleClient.stop()
    }
    let client = clients[profile.id] ?? CodexAppServerClient()
    clients[profile.id] = client
    clientHomes[profile.id] = normalizedHome
    let profileID = profile.id
    await client.setRateLimitHandler { bucket in
      Task { @MainActor in UsageStore.shared.mergeLiveBucket(bucket, profileID: profileID) }
    }

    do {
      try await client.start(codexHome: profile.codexHome)
      let accountResponse = try await client.readAccount()
      let limits = try await client.readRateLimits()
      let tokenUsage = try? await client.readTokenUsage()
      let snapshot = UsageSnapshot(
        account: accountResponse.account,
        limits: limits,
        tokenUsage: tokenUsage,
        fetchedAt: Date()
      )
      snapshots[profile.id] = snapshot
      states[profile.id] = .connected
      history.record(profileID: profile.id, response: limits)
      saveCache()
      checkNotifications(profile: profile, limits: limits)
    } catch {
      states[profile.id] = .failed(error.localizedDescription)
    }
  }

  func reconnect(_ profile: CodexProfile) async {
    if let client = clients.removeValue(forKey: profile.id) { await client.stop() }
    clientHomes.removeValue(forKey: profile.id)
    await refresh(profile)
  }

  func remove(_ profile: CodexProfile) async {
    if let client = clients.removeValue(forKey: profile.id) { await client.stop() }
    clientHomes.removeValue(forKey: profile.id)
    snapshots.removeValue(forKey: profile.id)
    states.removeValue(forKey: profile.id)
    history.delete(profileID: profile.id)
    saveCache()
  }

  func redeem(_ credit: ResetCredit?, for profile: CodexProfile) async throws -> String {
    let client = clients[profile.id] ?? CodexAppServerClient()
    clients[profile.id] = client
    try await client.start(codexHome: profile.codexHome)
    let result = try await client.consumeResetCredit(id: credit?.id)
    await refresh(profile)
    switch result.outcome {
    case "reset": return "Usage window reset"
    case "nothingToReset": return "No window is eligible yet"
    case "noCredit": return "No reset credit available"
    case "alreadyRedeemed": return "Reset already applied"
    default: return result.outcome
    }
  }

  private func mergeLiveBucket(_ bucket: RateLimitBucket, profileID: UUID) {
    guard var snapshot = snapshots[profileID], var response = snapshot.limits else { return }
    if response.rateLimits.id == bucket.id {
      response.rateLimits = merged(old: response.rateLimits, new: bucket)
    }
    if var buckets = response.rateLimitsByLimitId {
      buckets[bucket.id] = merged(old: buckets[bucket.id], new: bucket)
      response.rateLimitsByLimitId = buckets
    }
    snapshot.limits = response
    snapshot.fetchedAt = Date()
    snapshots[profileID] = snapshot
    saveCache()
  }

  private func merged(old: RateLimitBucket?, new: RateLimitBucket) -> RateLimitBucket {
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
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
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
