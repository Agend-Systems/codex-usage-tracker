import Charts
import SwiftUI

private enum SettingsPage: String, CaseIterable, Identifiable {
  case accounts = "Accounts"
  case appearance = "Appearance"
  case notifications = "Notifications"
  case history = "Usage history"
  case updates = "Updates"
  case about = "About"

  var id: String { rawValue }
  var icon: String {
    switch self {
    case .accounts: return "person.crop.circle"
    case .appearance: return "paintbrush"
    case .notifications: return "bell"
    case .history: return "chart.xyaxis.line"
    case .updates: return "arrow.triangle.2.circlepath"
    case .about: return "info.circle"
    }
  }
}

struct SettingsView: View {
  @ObservedObject private var preferences = TrackerPreferences.shared
  @ObservedObject private var store = UsageStore.shared
  @ObservedObject private var history = HistoryStore.shared
  @State private var selection: SettingsPage? = .accounts

  var body: some View {
    NavigationSplitView {
      List(SettingsPage.allCases, selection: $selection) { page in
        Label(page.rawValue, systemImage: page.icon).tag(page)
      }
      .navigationSplitViewColumnWidth(190)
      .safeAreaInset(edge: .bottom) {
        Label("Private by design", systemImage: "lock.shield.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding()
      }
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          pageHeader(selection ?? .accounts)
          pageContent(selection ?? .accounts)
        }
        .padding(28)
        .frame(maxWidth: 760, alignment: .leading)
      }
      .background(.ultraThinMaterial)
    }
    .frame(minWidth: 820, minHeight: 570)
  }

  private func pageHeader(_ page: SettingsPage) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(page.rawValue).font(.largeTitle.bold())
      Text(subtitle(for: page)).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func pageContent(_ page: SettingsPage) -> some View {
    switch page {
    case .accounts: accountsPage
    case .appearance: appearancePage
    case .notifications: notificationsPage
    case .history: historyPage
    case .updates: updatesPage
    case .about: aboutPage
    }
  }

  private var accountsPage: some View {
    VStack(spacing: 16) {
      SettingCard(
        title: "Codex profiles",
        subtitle: "Track multiple accounts without copying or storing credentials."
      ) {
        HStack(alignment: .top, spacing: 18) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(preferences.profiles) { profile in
              Button {
                preferences.activeProfileID = profile.id
              } label: {
                HStack {
                  StatusDot(
                    color: (store.states[profile.id] ?? .idle) == .connected
                      ? TrackerDesign.green : .secondary)
                  Text(profile.name)
                  Spacer()
                  if profile.id == preferences.activeProfileID { Image(systemName: "checkmark") }
                }
                .padding(9)
                .background(
                  profile.id == preferences.activeProfileID
                    ? Color.accentColor.opacity(0.13) : .clear,
                  in: RoundedRectangle(cornerRadius: 8))
              }
              .buttonStyle(.plain)
            }
            HStack {
              Button("Add", systemImage: "plus") { preferences.addProfile() }
              Button(role: .destructive) {
                let profile = preferences.activeProfile
                preferences.delete(profile)
                Task { await store.remove(profile) }
              } label: {
                Label("Remove", systemImage: "minus")
              }
              .disabled(preferences.profiles.count == 1)
            }
          }
          .frame(width: 190)
          Divider()
          profileEditor
        }
      }
    }
  }

  private var profileEditor: some View {
    let profile = preferences.activeProfile
    return VStack(alignment: .leading, spacing: 14) {
      LabeledContent("Profile name") {
        TextField("Personal", text: profileBinding(\.name)).frame(width: 260)
      }
      LabeledContent("Codex home") {
        TextField("Default: $CODEX_HOME or ~/.codex", text: optionalProfileBinding(\.codexHome))
          .frame(width: 330)
      }
      Text(
        "The app starts `codex app-server` with this CODEX_HOME. Authentication remains managed by Codex."
      )
      .font(.caption).foregroundStyle(.secondary)
      Toggle("Show this profile in the menu bar", isOn: profileBinding(\.isVisible))
      HStack {
        Button("Test connection") { Task { await store.reconnect(preferences.activeProfile) } }
          .buttonStyle(.borderedProminent)
          .tint(TrackerDesign.green)
        if case .failed(let message) = store.states[profile.id] {
          Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        } else {
          Text((store.states[profile.id] ?? .idle).label).font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      launcherControls(profile)
    }
  }

  private func launcherControls(_ profile: CodexProfile) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Terminal launcher").font(.headline)
      Text(
        "Install `codex-\(TerminalLauncherService.slug(for: profile.name))` in ~/.local/bin for this account."
      )
      .font(.caption).foregroundStyle(.secondary)
      HStack {
        Button(
          TerminalLauncherService.isInstalled(for: profile)
            ? "Reinstall launcher" : "Install launcher"
        ) {
          _ = try? TerminalLauncherService.install(for: profile)
        }
        if TerminalLauncherService.isInstalled(for: profile) {
          Button("Remove", role: .destructive) {
            try? TerminalLauncherService.uninstall(for: profile)
          }
        }
      }
    }
  }

  private var appearancePage: some View {
    VStack(spacing: 16) {
      SettingCard(
        title: "Menu bar", subtitle: "Choose how much information is visible at a glance."
      ) {
        Picker("Icon style", selection: $preferences.iconStyle) {
          ForEach(MenuIconStyle.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Show remaining usage instead of used usage", isOn: $preferences.showRemaining)
      }
      SettingCard(title: "Behaviour") {
        Picker("Refresh interval", selection: $preferences.refreshInterval) {
          Text("30 seconds").tag(TimeInterval(30))
          Text("1 minute").tag(TimeInterval(60))
          Text("5 minutes").tag(TimeInterval(300))
          Text("15 minutes").tag(TimeInterval(900))
        }
        Toggle("Launch at login", isOn: $preferences.launchAtLogin)
      }
    }
  }

  private var notificationsPage: some View {
    SettingCard(
      title: "Usage alerts",
      subtitle: "Receive one alert when a rolling window crosses each threshold."
    ) {
      thresholdSlider("Warning", value: $preferences.warningThreshold, color: TrackerDesign.amber)
      thresholdSlider("Critical", value: $preferences.criticalThreshold, color: TrackerDesign.red)
      Text("Alerts reset automatically after usage drops below the warning threshold.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func thresholdSlider(_ title: String, value: Binding<Double>, color: Color) -> some View {
    HStack {
      Circle().fill(color).frame(width: 9, height: 9)
      Text(title).frame(width: 65, alignment: .leading)
      Slider(value: value, in: 50...100, step: 5)
      Text("\(Int(value.wrappedValue))%").monospacedDigit().frame(width: 44, alignment: .trailing)
    }
  }

  private var historyPage: some View {
    let points = history.points(for: preferences.activeProfileID)
    return VStack(spacing: 16) {
      SettingCard(
        title: "Rolling-window history", subtitle: "Snapshots are retained locally for 90 days."
      ) {
        if points.isEmpty {
          ContentUnavailableView(
            "No history yet", systemImage: "chart.xyaxis.line",
            description: Text("Usage snapshots appear after the first successful refresh.")
          )
          .frame(height: 250)
        } else {
          Chart(points.suffix(500)) { point in
            if let primary = point.primaryPercent {
              LineMark(
                x: .value("Time", point.date), y: .value("Usage", primary),
                series: .value("Window", "Session")
              )
              .foregroundStyle(TrackerDesign.green)
            }
            if let secondary = point.secondaryPercent {
              LineMark(
                x: .value("Time", point.date), y: .value("Usage", secondary),
                series: .value("Window", "Weekly")
              )
              .foregroundStyle(TrackerDesign.amber)
            }
          }
          .chartYScale(domain: 0...100)
          .frame(height: 280)
        }
        Button("Export CSV…", systemImage: "square.and.arrow.up") {
          history.exportCSV(profileID: preferences.activeProfileID)
        }
        .disabled(points.isEmpty)
      }
    }
  }

  private var updatesPage: some View {
    VStack(spacing: 16) {
      SettingCard(
        title: "Software updates",
        subtitle:
          "Release publishing is intentionally disabled until this fork has its own repository and signing keys."
      ) {
        LabeledContent(
          "Installed version",
          value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "Development")
        LabeledContent(
          "Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
        Text("See RELEASING.md in the source repository to configure signing and publishing.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var aboutPage: some View {
    VStack(spacing: 16) {
      SettingCard(
        title: "Codex Usage Tracker",
        subtitle: "A private, native macOS companion for understanding Codex usage."
      ) {
        HStack(spacing: 18) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable().frame(width: 88, height: 88)
          VStack(alignment: .leading, spacing: 7) {
            Label("Credentials stay with Codex", systemImage: "lock.fill")
            Label("No analytics or cloud sync", systemImage: "icloud.slash.fill")
            Label("Built with SwiftUI", systemImage: "swift")
          }
        }
        Divider()
        Text(
          "Independent software; not affiliated with or endorsed by OpenAI. Derived from the MIT-licensed Claude Usage Tracker project, with its copyright notice preserved in LICENSE."
        )
        .font(.caption).foregroundStyle(.secondary)
        Link(
          "Codex app-server documentation",
          destination: URL(string: "https://developers.openai.com/codex/app-server/")!)
      }
    }
  }

  private func subtitle(for page: SettingsPage) -> String {
    switch page {
    case .accounts: return "Connect Codex accounts through their existing local configuration."
    case .appearance: return "Make the tracker fit your menu bar and workflow."
    case .notifications: return "Know before a rolling limit interrupts your work."
    case .history: return "See how your usage changes over time."
    case .updates: return "Review the installed build and release configuration."
    case .about: return "Privacy, attribution, and technical details."
    }
  }

  private func profileBinding<Value>(_ keyPath: WritableKeyPath<CodexProfile, Value>) -> Binding<
    Value
  > {
    Binding {
      preferences.activeProfile[keyPath: keyPath]
    } set: { value in
      var profile = preferences.activeProfile
      profile[keyPath: keyPath] = value
      preferences.update(profile)
    }
  }

  private func optionalProfileBinding(_ keyPath: WritableKeyPath<CodexProfile, String?>) -> Binding<
    String
  > {
    Binding {
      preferences.activeProfile[keyPath: keyPath] ?? ""
    } set: { value in
      var profile = preferences.activeProfile
      profile[keyPath: keyPath] =
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
      preferences.update(profile)
    }
  }
}
