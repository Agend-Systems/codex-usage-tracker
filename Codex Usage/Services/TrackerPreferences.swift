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

  private struct Stored: Codable {
    var profiles: [CodexProfile]
    var activeProfileID: UUID
    var iconStyle: MenuIconStyle
    var showRemaining: Bool
    var refreshInterval: TimeInterval
    var warningThreshold: Double
    var criticalThreshold: Double
    var launchAtLogin: Bool
  }

  private let defaults = UserDefaults.standard
  private var isLoading = true
  private var isUpdatingLaunchAtLogin = false

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
      launchAtLogin: launchAtLogin
    )
    if let data = try? JSONEncoder().encode(stored) {
      defaults.set(data, forKey: "tracker.preferences.v1")
    }
  }

  private func updateLaunchAtLogin() {
    guard !isLoading else { return }
    do {
      if launchAtLogin {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }
}

@MainActor
final class HistoryStore: ObservableObject {
  static let shared = HistoryStore()
  @Published private(set) var points: [HistoryPoint] = []

  private let key = "tracker.history.v1"
  private let defaults = UserDefaults.standard

  private init() {
    guard let data = defaults.data(forKey: key),
      let decoded = try? JSONDecoder().decode([HistoryPoint].self, from: data)
    else { return }
    points = decoded
  }

  func record(profileID: UUID, response: RateLimitsResponse) {
    let now = Date()
    let newPoints = response.buckets.map {
      HistoryPoint(
        profileId: profileID,
        date: now,
        bucketId: $0.id,
        primaryPercent: $0.primary?.usedPercent,
        secondaryPercent: $0.secondary?.usedPercent
      )
    }
    points.append(contentsOf: newPoints)
    let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
    points.removeAll { $0.date < cutoff }
    if let data = try? JSONEncoder().encode(points) { defaults.set(data, forKey: key) }
  }

  func points(for profileID: UUID) -> [HistoryPoint] {
    points.filter { $0.profileId == profileID }
  }

  func delete(profileID: UUID) {
    points.removeAll { $0.profileId == profileID }
    if let data = try? JSONEncoder().encode(points) { defaults.set(data, forKey: key) }
  }

  func exportCSV(profileID: UUID) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = "codex-usage-history.csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var rows = ["timestamp,bucket,primary_percent,secondary_percent"]
    let formatter = ISO8601DateFormatter()
    for point in points(for: profileID) {
      rows.append(
        [
          formatter.string(from: point.date),
          point.bucketId.replacingOccurrences(of: ",", with: " "),
          point.primaryPercent.map { String(format: "%.2f", $0) } ?? "",
          point.secondaryPercent.map { String(format: "%.2f", $0) } ?? "",
        ].joined(separator: ","))
    }
    try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
  }
}
