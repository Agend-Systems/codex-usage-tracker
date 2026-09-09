import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

enum MenuIconStyle: String, Codable, CaseIterable, Identifiable {
  case ring
  case percentage
  case bar
  case compact

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
}

@MainActor
final class TrackerPreferences: ObservableObject {
  static let shared = TrackerPreferences()

  @Published var profiles: [CodexProfile] { didSet { save() } }
  @Published var activeProfileID: UUID { didSet { save() } }
  @Published var iconStyle: MenuIconStyle { didSet { save() } }
  @Published var showRemaining: Bool { didSet { save() } }
  @Published var refreshInterval: TimeInterval { didSet { save() } }
  @Published var warningThreshold: Double {
    didSet {
      if warningThreshold > criticalThreshold { criticalThreshold = warningThreshold }
      save()
    }
  }
  @Published var criticalThreshold: Double {
    didSet {
      if criticalThreshold < warningThreshold { warningThreshold = criticalThreshold }
      save()
    }
  }
  @Published var launchAtLogin: Bool {
    didSet {
      updateLaunchAtLogin()
      save()
    }
  }
  @Published private(set) var launchAtLoginError: String?

  private struct Stored: Codable {
    var profiles: [CodexProfile]
    var activeProfileID: UUID
    var iconStyle: MenuIconStyle
    var showRemaining: Bool
    var refreshInterval: TimeInterval
    var warningThreshold: Double
    var criticalThreshold: Double
    var launchAtLogin: Bool
    var resetCreditIdempotencyKeys: [String: String]?
  }

  private let defaults = UserDefaults.standard
  private var isLoading = true
  private var isUpdatingLaunchAtLogin = false
  private var resetCreditIdempotencyKeys: [String: String] = [:]

  private init() {
    if let data = defaults.data(forKey: "tracker.preferences.v1"),
      let stored = try? JSONDecoder().decode(Stored.self, from: data),
      !stored.profiles.isEmpty
    {
      profiles = stored.profiles
      activeProfileID = stored.activeProfileID
      iconStyle = stored.iconStyle
      showRemaining = stored.showRemaining
      refreshInterval = stored.refreshInterval
      warningThreshold = stored.warningThreshold
      criticalThreshold = stored.criticalThreshold
      launchAtLogin = SMAppService.mainApp.status == .enabled
      resetCreditIdempotencyKeys = stored.resetCreditIdempotencyKeys ?? [:]
    } else {
      let profile = CodexProfile()
      profiles = [profile]
      activeProfileID = profile.id
      iconStyle = .ring
      showRemaining = false
      refreshInterval = 60
      warningThreshold = 75
      criticalThreshold = 90
      launchAtLogin = false
      resetCreditIdempotencyKeys = [:]
    }
    isLoading = false
  }

  var activeProfile: CodexProfile {
    profiles.first(where: { $0.id == activeProfileID }) ?? profiles[0]
  }

  func addProfile() {
    let profile = CodexProfile(name: "Account \(profiles.count + 1)")
    profiles.append(profile)
    activeProfileID = profile.id
  }

  func update(_ profile: CodexProfile) {
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    profiles[index] = profile
  }

  func delete(_ profile: CodexProfile) {
    guard profiles.count > 1 else { return }
    profiles.removeAll { $0.id == profile.id }
    if activeProfileID == profile.id { activeProfileID = profiles[0].id }
  }

  func resetCreditIdempotencyKey(profileID: UUID, creditID: String?) -> String {
    let intent = "\(profileID.uuidString):\(creditID ?? "automatic")"
    if let existing = resetCreditIdempotencyKeys[intent] { return existing }
    let key = UUID().uuidString
    resetCreditIdempotencyKeys[intent] = key
    save()
    return key
  }

  func clearResetCreditIdempotencyKey(profileID: UUID, creditID: String?) {
    let intent = "\(profileID.uuidString):\(creditID ?? "automatic")"
    resetCreditIdempotencyKeys.removeValue(forKey: intent)
    save()
  }

  func clearAllResetCreditIdempotencyKeys() {
    resetCreditIdempotencyKeys.removeAll()
    save()
  }

  func clearResetCreditIdempotencyKeys(profileID: UUID) {
    let prefix = profileID.uuidString + ":"
    resetCreditIdempotencyKeys = resetCreditIdempotencyKeys.filter {
      !$0.key.hasPrefix(prefix)
    }
    save()
  }

  private func save() {
    guard !isLoading, !isUpdatingLaunchAtLogin else { return }
    isUpdatingLaunchAtLogin = true
    defer { isUpdatingLaunchAtLogin = false }
    let stored = Stored(
      profiles: profiles,
      activeProfileID: activeProfileID,
      iconStyle: iconStyle,
      showRemaining: showRemaining,
      refreshInterval: refreshInterval,
      warningThreshold: warningThreshold,
      criticalThreshold: criticalThreshold,
      launchAtLogin: launchAtLogin,
      resetCreditIdempotencyKeys: resetCreditIdempotencyKeys
    )
    if let data = try? JSONEncoder().encode(stored) {
      defaults.set(data, forKey: "tracker.preferences.v1")
    }
  }

  private func updateLaunchAtLogin() {
    guard !isLoading, !isUpdatingLaunchAtLogin else { return }
    isUpdatingLaunchAtLogin = true
    defer { isUpdatingLaunchAtLogin = false }
    do {
      if launchAtLogin {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginError = nil
    } catch {
      launchAtLoginError = error.localizedDescription
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}

private actor HistoryFilePersistence {
  private let url: URL
  private var latestGeneration = 0

  init(url: URL) {
    self.url = url
  }

  func save(_ points: [HistoryPoint], generation: Int) throws {
    guard generation >= latestGeneration else { return }
    latestGeneration = generation
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(points)
    try data.write(to: url, options: .atomic)
  }
}

@MainActor
final class HistoryStore: ObservableObject {
  static let shared = HistoryStore()
  @Published private(set) var points: [HistoryPoint] = []

  nonisolated private static let minimumSampleInterval: TimeInterval = 5 * 60
  private static let maximumPointCount = 50_000
  private static let legacyKey = "tracker.history.v1"
  private static let historyURL: URL = {
    let root =
      (try? FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )) ?? FileManager.default.homeDirectoryForCurrentUser
    return
      root
      .appendingPathComponent("Codex Usage Tracker", isDirectory: true)
      .appendingPathComponent("history.json")
  }()

  private let persistence: HistoryFilePersistence
  private var generation = 0

  private init() {
    persistence = HistoryFilePersistence(url: Self.historyURL)
    if let data = try? Data(contentsOf: Self.historyURL),
      let decoded = try? JSONDecoder().decode([HistoryPoint].self, from: data)
    {
      points = decoded
      return
    }
    if let legacyData = UserDefaults.standard.data(forKey: Self.legacyKey),
      let decoded = try? JSONDecoder().decode([HistoryPoint].self, from: legacyData)
    {
      points = decoded
      UserDefaults.standard.removeObject(forKey: Self.legacyKey)
      generation = 1
      let persistence = persistence
      Task { try? await persistence.save(decoded, generation: 1) }
    }
  }

  func record(profileID: UUID, response: RateLimitsResponse, now: Date = Date()) {
    var updated = points
    var changed = false
    for bucket in response.buckets {
      let newest = updated.last {
        $0.profileId == profileID && $0.bucketId == bucket.id
      }
      guard Self.shouldRecord(lastDate: newest?.date, now: now) else { continue }
      updated.append(
        HistoryPoint(
          profileId: profileID,
          date: now,
          bucketId: bucket.id,
          primaryPercent: bucket.primary?.usedPercent,
          secondaryPercent: bucket.secondary?.usedPercent
        ))
      changed = true
    }

    let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
    let beforePrune = updated.count
    updated.removeAll { $0.date < cutoff }
    if updated.count > Self.maximumPointCount {
      updated.removeFirst(updated.count - Self.maximumPointCount)
    }
    changed = changed || updated.count != beforePrune
    guard changed else { return }
    points = updated
    persist()
  }

  func points(for profileID: UUID) -> [HistoryPoint] {
    points.filter { $0.profileId == profileID }
  }

  func delete(profileID: UUID) {
    let previousCount = points.count
    points.removeAll { $0.profileId == profileID }
    if points.count != previousCount { persist() }
  }

  func deleteAll() {
    guard !points.isEmpty else { return }
    points.removeAll()
    persist()
  }

  func exportCSV(profileID: UUID) throws {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = "codex-usage-history.csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var rows = ["timestamp,bucket,primary_percent,secondary_percent"]
    let formatter = ISO8601DateFormatter()
    for point in points(for: profileID) {
      rows.append(
        [
          Self.csvField(formatter.string(from: point.date)),
          Self.csvField(point.bucketId),
          Self.csvField(point.primaryPercent.map { String(format: "%.2f", $0) } ?? ""),
          Self.csvField(point.secondaryPercent.map { String(format: "%.2f", $0) } ?? ""),
        ].joined(separator: ","))
    }
    try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }

  nonisolated static func csvField(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
    let needsFormulaGuard = "=+-@".contains(escaped.first ?? " ")
    return "\"\(needsFormulaGuard ? "'" : "")\(escaped)\""
  }

  nonisolated static func shouldRecord(lastDate: Date?, now: Date) -> Bool {
    lastDate.map { now.timeIntervalSince($0) >= minimumSampleInterval } ?? true
  }

  private func persist() {
    generation += 1
    let currentGeneration = generation
    let snapshot = points
    let persistence = persistence
    Task {
      try? await persistence.save(snapshot, generation: currentGeneration)
    }
  }
}
