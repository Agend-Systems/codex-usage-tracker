import Foundation

struct CodexProfile: Codable, Identifiable, Equatable {
  var id: UUID
  var name: String
  var codexHome: String?
  var isVisible: Bool

  init(
    id: UUID = UUID(), name: String = "Personal", codexHome: String? = nil, isVisible: Bool = true
  ) {
    self.id = id
    self.name = name
    self.codexHome = codexHome?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.isVisible = isVisible
  }

  var displayPath: String {
    codexHome ?? "$CODEX_HOME or ~/.codex"
  }
}

struct CodexAccount: Codable, Equatable {
  enum Kind: String, Codable {
    case chatgpt
    case apiKey
    case amazonBedrock
    case unknown
  }

  var kind: Kind
  var email: String?
  var planType: String?

  private enum CodingKeys: String, CodingKey { case type, email, planType }

  init(kind: Kind, email: String? = nil, planType: String? = nil) {
    self.kind = kind
    self.email = email
    self.planType = planType
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
    kind = Kind(rawValue: raw) ?? .unknown
    email = try container.decodeIfPresent(String.self, forKey: .email)
    planType = try container.decodeIfPresent(String.self, forKey: .planType)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind.rawValue, forKey: .type)
    try container.encodeIfPresent(email, forKey: .email)
    try container.encodeIfPresent(planType, forKey: .planType)
  }
}

struct RateLimitWindow: Codable, Equatable {
  var usedPercent: Double
  var windowDurationMins: Int?
  var resetsAt: Int?

  var resetDate: Date? {
    resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
  }

  var remainingPercent: Double {
    max(0, 100 - usedPercent)
  }

  var durationLabel: String {
    guard let minutes = windowDurationMins else { return "Rolling window" }
    if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week rolling window" }
    if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day rolling window" }
    if minutes % 60 == 0 { return "\(minutes / 60)-hour rolling window" }
    return "\(minutes)-minute rolling window"
  }
}

struct CreditSnapshot: Codable, Equatable {
  var hasCredits: Bool
  var unlimited: Bool
  var balance: String?
}

struct SpendControlLimitSnapshot: Codable, Equatable {
  var limit: String
  var used: String
  var remainingPercent: Double
  var resetsAt: Int

  var resetDate: Date { Date(timeIntervalSince1970: TimeInterval(resetsAt)) }
  var usedPercent: Double { max(0, min(100, 100 - remainingPercent)) }
}

struct RateLimitBucket: Codable, Identifiable, Equatable {
  var limitId: String?
  var limitName: String?
  var planType: String?
  var primary: RateLimitWindow?
  var secondary: RateLimitWindow?
  var credits: CreditSnapshot?
  var individualLimit: SpendControlLimitSnapshot?
  var rateLimitReachedType: String?
  var spendControlReached: Bool?

  var id: String { limitId ?? limitName ?? "codex" }
  var displayName: String {
    guard let raw = limitName?.nilIfEmpty ?? limitId?.nilIfEmpty else { return "Codex" }
    if raw.lowercased() == "codex" { return "Codex" }
    return raw.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

struct ResetCredit: Codable, Identifiable, Equatable {
  var id: String
  var resetType: String
  var status: String
  var grantedAt: Int
  var expiresAt: Int?
  var title: String?
  var description: String?
}

struct ResetCreditsSummary: Codable, Equatable {
  var availableCount: Int
  var credits: [ResetCredit]?
}

struct RateLimitsResponse: Codable, Equatable {
  var accountId: String?
  var rateLimits: RateLimitBucket
  var rateLimitsByLimitId: [String: RateLimitBucket]?
  var rateLimitResetCredits: ResetCreditsSummary?

  var buckets: [RateLimitBucket] {
    if let values = rateLimitsByLimitId, !values.isEmpty {
      return values.values.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
    }
    return [rateLimits]
  }
}

struct TokenUsageSummary: Codable, Equatable {
  var lifetimeTokens: Int?
  var peakDailyTokens: Int?
  var longestRunningTurnSec: Int?
  var currentStreakDays: Int?
  var longestStreakDays: Int?
}

struct DailyUsageBucket: Codable, Identifiable, Equatable {
  var startDate: String
  var tokens: Int
  var id: String { startDate }

  var date: Date? {
    Self.dateFormatter.date(from: startDate)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}

struct TokenUsageResponse: Codable, Equatable {
  var summary: TokenUsageSummary
  var dailyUsageBuckets: [DailyUsageBucket]?
}

struct UsageSnapshot: Codable, Equatable {
  var account: CodexAccount?
  var limits: RateLimitsResponse?
  var tokenUsage: TokenUsageResponse?
  var fetchedAt: Date
}

struct HistoryPoint: Codable, Identifiable, Equatable {
  var id: UUID = UUID()
  var profileId: UUID
  var date: Date
  var bucketId: String
  var primaryPercent: Double?
  var secondaryPercent: Double?
}

enum ConnectionState: Equatable {
  case idle
  case connecting
  case connected
  case failed(String)

  var label: String {
    switch self {
    case .idle: return "Ready"
    case .connecting: return "Connecting…"
    case .connected: return "Connected"
    case .failed: return "Needs attention"
    }
  }

  var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}

enum CodexTrackerError: LocalizedError, Equatable {
  case executableNotFound
  case serverExited(String)
  case malformedResponse
  case rpc(code: Int, message: String)
  case incompatibleCLI
  case notAuthenticated

  var errorDescription: String? {
    switch self {
    case .executableNotFound:
      return
        "Codex CLI was not found. Install Codex and make sure the `codex` command is available."
    case .serverExited(let detail):
      return detail.isEmpty
        ? "Codex app-server stopped unexpectedly." : "Codex app-server stopped: \(detail)"
    case .malformedResponse:
      return "Codex returned a response the tracker could not understand."
    case .rpc(_, let message):
      return message
    case .incompatibleCLI:
      return
        "This Codex version does not expose the usage APIs required by the tracker. Please update Codex."
    case .notAuthenticated:
      return "Sign in to Codex with ChatGPT, then refresh."
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
