import SwiftUI

struct MenuBarLabel: View {
  @ObservedObject var preferences: TrackerPreferences
  @ObservedObject var store: UsageStore

  private var usage: Double? {
    store.activeSnapshot?.limits?.buckets.first?.primary?.usedPercent
  }

  private func displayValue(for usage: Double) -> Int {
    Int((preferences.showRemaining ? 100 - usage : usage).rounded())
  }

  var body: some View {
    Group {
      if let usage {
        switch preferences.iconStyle {
        case .ring:
          HStack(spacing: 4) {
            ZStack {
              Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
              Circle()
                .trim(from: 0, to: max(0.02, min(usage, 100) / 100))
                .stroke(
                  TrackerDesign.usageColor(
                    usage,
                    warning: preferences.warningThreshold,
                    critical: preferences.criticalThreshold
                  ),
                  style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            }
            .frame(width: 14, height: 14)
            Text("\(displayValue(for: usage))%").monospacedDigit()
          }
        case .percentage:
          Text("\(displayValue(for: usage))%").monospacedDigit()
        case .bar:
          HStack(spacing: 4) {
            Image(systemName: "terminal")
            Text("\(displayValue(for: usage))%").monospacedDigit()
          }
        case .compact:
          StatusDot(
            color: TrackerDesign.usageColor(
              usage,
              warning: preferences.warningThreshold,
              critical: preferences.criticalThreshold),
            label: store.activeState.label)
        }
      } else {
        switch preferences.iconStyle {
        case .compact:
          StatusDot(
            color: store.activeState == .connecting ? TrackerDesign.amber : TrackerDesign.red,
            label: store.activeState.label)
        case .ring:
          HStack(spacing: 4) {
            Image(systemName: "circle.dotted")
            Text("—").monospacedDigit()
          }
        case .percentage:
          Text("—").monospacedDigit()
        case .bar:
          HStack(spacing: 4) {
            Image(systemName: "terminal")
            Text("—").monospacedDigit()
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Codex usage, \(preferences.activeProfile.name)")
    .accessibilityValue(
      usage.map {
        preferences.showRemaining
          ? "\(Int((100 - $0).rounded())) percent remaining"
          : "\(Int($0.rounded())) percent used"
      } ?? store.activeState.label)
  }
}
