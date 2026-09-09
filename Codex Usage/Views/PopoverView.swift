import Charts
import SwiftUI

struct PopoverView: View {
  @ObservedObject private var preferences = TrackerPreferences.shared
  @ObservedObject private var store = UsageStore.shared
  @Environment(\.openSettings) private var openSettings
  @State private var creditToRedeem: ResetCredit?
  @State private var showingResetConfirmation = false
  @State private var actionMessage: String?

  private var profile: CodexProfile { preferences.activeProfile }
  private var snapshot: UsageSnapshot? { store.snapshots[profile.id] }
  private var state: ConnectionState { store.states[profile.id] ?? .idle }

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        header
        Divider()
        statusRow

        if case .failed(let message) = state {
          errorCard(message)
        }

        if let limits = snapshot?.limits {
          ForEach(limits.buckets) { bucket in
            bucketSection(bucket)
          }
          if let resetCredits = limits.rateLimitResetCredits, resetCredits.availableCount > 0 {
            resetCreditsCard(resetCredits)
          }
        } else if !state.isFailure {
          loadingCard
        }

        if let usage = snapshot?.tokenUsage {
          tokenUsageCard(usage)
        }

        footer
      }
      .padding(16)
    }
    .frame(width: TrackerDesign.popoverWidth, height: 620)
    .background(.ultraThinMaterial)
    .alert("Use a rate-limit reset?", isPresented: $showingResetConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Reset usage window") {
        Task {
          do { actionMessage = try await store.redeem(creditToRedeem, for: profile) } catch {
            actionMessage = error.localizedDescription
          }
        }
      }
    } message: {
      Text("This consumes one earned reset credit. The action cannot be undone.")
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "terminal.fill")
        .font(.title2)
        .foregroundStyle(TrackerDesign.green)
      Menu {
        ForEach(preferences.profiles) { item in
          Button {
            preferences.activeProfileID = item.id
            Task { await store.refresh(item) }
          } label: {
            if item.id == profile.id {
              Label(item.name, systemImage: "checkmark")
            } else {
              Text(item.name)
            }
          }
        }
      } label: {
        HStack(spacing: 4) {
          Text(profile.name).font(.title2.bold())
          Image(systemName: "chevron.down").font(.caption.bold())
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      Spacer()
      Button {
        Task { await store.refresh(profile) }
      } label: {
        Image(systemName: "arrow.clockwise")
          .rotationEffect(store.isRefreshing ? .degrees(360) : .zero)
          .animation(
            store.isRefreshing
              ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
            value: store.isRefreshing)
      }
      .buttonStyle(.plain)
      .help("Refresh")
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape.fill")
      }
      .buttonStyle(.plain)
      .help("Settings")
    }
  }

  private var statusRow: some View {
    HStack(spacing: 8) {
      StatusDot(
        color: state == .connected
          ? TrackerDesign.green : state == .connecting ? TrackerDesign.amber : .red)
      VStack(alignment: .leading, spacing: 2) {
        Text(store.serviceStatus).font(.subheadline.weight(.medium))
        HStack(spacing: 5) {
          if let email = snapshot?.account?.email { Text(email) }
          if let plan = snapshot?.account?.planType ?? snapshot?.limits?.buckets.first?.planType {
            Text(plan.uppercased()).font(.caption2.bold()).padding(.horizontal, 5).padding(
              .vertical, 2
            ).background(.secondary.opacity(0.15), in: Capsule())
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Text(state.label).font(.caption).foregroundStyle(.secondary)
    }
  }

  private func bucketSection(_ bucket: RateLimitBucket) -> some View {
    VStack(spacing: 10) {
      if (snapshot?.limits?.buckets.count ?? 0) > 1 {
        Text(bucket.displayName.uppercased())
          .font(.caption.bold())
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let primary = bucket.primary {
        RateLimitCard(
          title: "Session usage", window: primary, showRemaining: preferences.showRemaining)
      }
      if let secondary = bucket.secondary {
        RateLimitCard(
          title: "Weekly usage", window: secondary, showRemaining: preferences.showRemaining)
      }
      if let credits = bucket.credits, credits.hasCredits {
        creditsCard(credits)
      }
      if let spendLimit = bucket.individualLimit {
        spendControlCard(spendLimit, reached: bucket.spendControlReached == true)
      }
    }
  }

  private func spendControlCard(_ limit: SpendControlLimitSnapshot, reached: Bool) -> some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Spend control").font(.headline)
            Text("\(limit.used) of \(limit.limit)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(Int(limit.remainingPercent.rounded()))% left")
            .font(.subheadline.bold())
            .foregroundStyle(
              reached ? TrackerDesign.red : TrackerDesign.usageColor(limit.usedPercent))
        }
        UsageProgress(value: limit.usedPercent, showRemaining: true)
        HStack {
          Text("Resets ") + Text(limit.resetDate, style: .relative)
          Spacer()
          if reached { Text("Limit reached").foregroundStyle(TrackerDesign.red) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func creditsCard(_ credits: CreditSnapshot) -> some View {
    GlassCard {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Credits").font(.headline)
          Text(credits.unlimited ? "Unlimited balance" : "Available for additional Codex usage")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(credits.unlimited ? "∞" : credits.balance ?? "—")
          .font(.title2.bold()).monospacedDigit()
          .foregroundStyle(TrackerDesign.green)
      }
    }
  }

  private func resetCreditsCard(_ summary: ResetCreditsSummary) -> some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("Earned resets", systemImage: "arrow.counterclockwise.circle.fill").font(.headline)
          Spacer()
          Text("\(summary.availableCount)").font(.title2.bold()).foregroundStyle(
            TrackerDesign.green)
        }
        Text("Reset an eligible Codex rate-limit window without waiting for its timer.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Use reset credit…") {
          creditToRedeem = summary.credits?.first
          showingResetConfirmation = true
        }
        .buttonStyle(.borderedProminent)
        .tint(TrackerDesign.green)
      }
    }
  }

  private func tokenUsageCard(_ usage: TokenUsageResponse) -> some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text("Token activity").font(.headline)
            Text("Account-wide Codex activity").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          if let lifetime = usage.summary.lifetimeTokens {
            Text(lifetime.formatted(.number.notation(.compactName)))
              .font(.title3.bold()).monospacedDigit()
          }
        }
        if let buckets = usage.dailyUsageBuckets, !buckets.isEmpty {
          Chart(buckets.suffix(14)) { item in
            BarMark(
              x: .value("Day", item.date ?? .distantPast, unit: .day),
              y: .value("Tokens", item.tokens)
            )
            .foregroundStyle(TrackerDesign.green.gradient)
            .cornerRadius(2)
          }
          .chartXAxis(.hidden)
          .chartYAxis(.hidden)
          .frame(height: 64)
        }
        HStack {
          metric("Current streak", usage.summary.currentStreakDays.map { "\($0)d" } ?? "—")
          Spacer()
          metric(
            "Peak day",
            usage.summary.peakDailyTokens.map { $0.formatted(.number.notation(.compactName)) }
              ?? "—")
          Spacer()
          metric("Longest turn", usage.summary.longestRunningTurnSec.map(duration) ?? "—")
        }
      }
    }
  }

  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.subheadline.bold()).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func errorCard(_ message: String) -> some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 10) {
        Label("Unable to load usage", systemImage: "exclamationmark.triangle.fill")
          .font(.headline).foregroundStyle(TrackerDesign.amber)
        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        HStack {
          Button("Try again") { Task { await store.reconnect(profile) } }
          Button("Open settings") { openSettings() }
        }
      }
    }
  }

  private var loadingCard: some View {
    GlassCard {
      HStack {
        ProgressView()
        Text("Loading Codex usage…").foregroundStyle(.secondary)
        Spacer()
      }
    }
  }

  private var footer: some View {
    HStack {
      if let date = snapshot?.fetchedAt {
        Text("Updated ") + Text(date, style: .relative) + Text(" ago")
      } else {
        Text("No usage data yet")
      }
      if let actionMessage { Text(" · \(actionMessage)") }
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain)
    }
    .font(.caption2)
    .foregroundStyle(.tertiary)
  }

  private func duration(_ seconds: Int) -> String {
    if seconds >= 3_600 { return String(format: "%.1fh", Double(seconds) / 3_600) }
    if seconds >= 60 { return "\(seconds / 60)m" }
    return "\(seconds)s"
  }
}

struct RateLimitCard: View {
  var title: String
  var window: RateLimitWindow
  var showRemaining: Bool

  private var displayValue: Double { showRemaining ? window.remainingPercent : window.usedPercent }

  var body: some View {
    GlassCard {
      VStack(alignment: .leading, spacing: 11) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.title3.bold())
            Text(window.durationLabel).font(.subheadline).foregroundStyle(.secondary)
          }
          Spacer()
          Text("\(Int(displayValue.rounded()))%")
            .font(.title2.bold()).monospacedDigit()
            .foregroundStyle(TrackerDesign.usageColor(window.usedPercent))
        }
        UsageProgress(value: window.usedPercent, showRemaining: showRemaining)
        HStack {
          if let resetDate = window.resetDate {
            Text("Resets ") + Text(resetDate, style: .relative)
          } else {
            Text("Reset time unavailable")
          }
          Spacer()
          Text(showRemaining ? "remaining" : "used")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}
