import SwiftUI

enum TrackerDesign {
  static let green = Color(red: 0.27, green: 0.91, blue: 0.43)
  static let amber = Color(red: 1.0, green: 0.63, blue: 0.16)
  static let red = Color(red: 1.0, green: 0.28, blue: 0.31)
  static let popoverWidth: CGFloat = 390

  static func usageColor(_ value: Double) -> Color {
    if value >= 90 { return red }
    if value >= 75 { return amber }
    return green
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
          .stroke(.white.opacity(0.08), lineWidth: 1)
      }
  }
}

struct StatusDot: View {
  var color: Color
  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .shadow(color: color.opacity(0.7), radius: 4)
  }
}

struct UsageProgress: View {
  var value: Double
  var showRemaining: Bool

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.secondary.opacity(0.18))
        Capsule()
          .fill(TrackerDesign.usageColor(value).gradient)
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
