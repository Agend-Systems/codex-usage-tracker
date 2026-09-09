import AppKit
import SwiftUI

enum TrackerDesign {
  static let green = Color(
    nsColor: dynamicColor(
      name: "TrackerGreen",
      light: NSColor(red: 0.08, green: 0.45, blue: 0.20, alpha: 1),
      dark: NSColor(red: 0.27, green: 0.91, blue: 0.43, alpha: 1)))
  static let amber = Color(
    nsColor: dynamicColor(
      name: "TrackerAmber",
      light: NSColor(red: 0.55, green: 0.30, blue: 0.0, alpha: 1),
      dark: NSColor(red: 1.0, green: 0.63, blue: 0.16, alpha: 1)))
  static let red = Color(
    nsColor: dynamicColor(
      name: "TrackerRed",
      light: NSColor(red: 0.70, green: 0.08, blue: 0.10, alpha: 1),
      dark: NSColor(red: 1.0, green: 0.28, blue: 0.31, alpha: 1)))
  static let popoverWidth: CGFloat = 390

  static func usageColor(_ value: Double, warning: Double, critical: Double) -> Color {
    if value >= critical { return red }
    if value >= warning { return amber }
    return green
  }

  private static func dynamicColor(
    name: String, light: NSColor, dark: NSColor
  ) -> NSColor {
    NSColor(name: NSColor.Name(name)) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
  }
}

struct GlassCard<Content: View>: View {
  private let padding: CGFloat
  private let content: Content

  init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
    self.padding = padding
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .background(
        .quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
      }
  }
}

struct StatusDot: View {
  var color: Color
  var label: String

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .shadow(color: color.opacity(0.7), radius: 4)
      .accessibilityElement()
      .accessibilityLabel(label)
  }
}

struct UsageProgress: View {
  var value: Double
  var showRemaining: Bool
  var warningThreshold: Double
  var criticalThreshold: Double

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.secondary.opacity(0.18))
        Capsule()
          .fill(
            TrackerDesign.usageColor(
              value, warning: warningThreshold, critical: criticalThreshold
            ).gradient
          )
          .frame(width: proxy.size.width * max(0.01, min(value, 100) / 100))
      }
    }
    .frame(height: 7)
    .accessibilityLabel(
      showRemaining ? "\(Int(100 - value)) percent remaining" : "\(Int(value)) percent used")
  }
}

struct SettingCard<Content: View>: View {
  private let title: String
  private let subtitle: String?
  private let content: Content

  init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
    self.title = title
    self.subtitle = subtitle
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline)
        if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
      }
      content
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .background.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
    }
  }
}
