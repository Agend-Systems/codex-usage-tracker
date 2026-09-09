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

struct RateLimitWindow: Codable, Equatable, Sendable {
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

struct CreditSnapshot: Codable, Equatable, Sendable {
  var hasCredits: Bool? = nil
  var unlimited: Bool? = nil
  var balance: String? = nil
}

struct SpendControlLimitSnapshot: Codable, Equatable, Sendable {
  var limit: String? = nil
  var used: String? = nil
  var remainingPercent: Double? = nil
  var resetsAt: Int? = nil

  var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
  var usedPercent: Double? { remainingPercent.map { max(0, min(100, 100 - $0)) } }
}

struct RateLimitBucket: Codable, Identifiable, Equatable, Sendable {
  var limitId: String? = nil
  var limitName: String? = nil
  var planType: String? = nil
  var primary: RateLimitWindow? = nil
  var secondary: RateLimitWindow? = nil
  var credits: CreditSnapshot? = nil
  var individualLimit: SpendControlLimitSnapshot? = nil
  var rateLimitReachedType: String? = nil
  var spendControlReached: Bool? = nil

  private enum CodingKeys: String, CodingKey {
    case limitId
    case limitName
    case planType
    case primary
    case secondary
    case credits
    case individualLimit
    case rateLimitReachedType
    case spendControlReached
  }

  init(
    limitId: String? = nil,
    limitName: String? = nil,
    planType: String? = nil,
    primary: RateLimitWindow? = nil,
    secondary: RateLimitWindow? = nil,
    credits: CreditSnapshot? = nil,
    individualLimit: SpendControlLimitSnapshot? = nil,
    rateLimitReachedType: String? = nil,
    spendControlReached: Bool? = nil
  ) {
    self.limitId = limitId
    self.limitName = limitName
    self.planType = planType
    self.primary = primary
    self.secondary = secondary
    self.credits = credits
    self.individualLimit = individualLimit
    self.rateLimitReachedType = rateLimitReachedType
    self.spendControlReached = spendControlReached
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    limitId = try? container.decodeIfPresent(String.self, forKey: .limitId)
    limitName = try? container.decodeIfPresent(String.self, forKey: .limitName)
    planType = try? container.decodeIfPresent(String.self, forKey: .planType)
    primary = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .primary)
    secondary = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .secondary)
    credits = try? container.decodeIfPresent(CreditSnapshot.self, forKey: .credits)
    individualLimit =
      try? container.decodeIfPresent(SpendControlLimitSnapshot.self, forKey: .individualLimit)
    rateLimitReachedType =
      try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
    spendControlReached = try? container.decodeIfPresent(Bool.self, forKey: .spendControlReached)
  }

  var id: String { limitId ?? limitName ?? "codex" }
  var displayName: String {
    guard let raw = limitName?.nilIfEmpty ?? limitId?.nilIfEmpty else { return "Codex" }
    if raw.lowercased() == "codex" { return "Codex" }
    return raw.replacingOccurrences(of: "_", with: " ").capitalized
  }
}

struct ResetCredit: Codable, Equatable, Sendable {
  var id: String? = nil
  var resetType: String? = nil
  var status: String? = nil
  var grantedAt: Int? = nil
  var expiresAt: Int? = nil
  var title: String? = nil
  var description: String? = nil
}

struct ResetCreditsSummary: Codable, Equatable, Sendable {
  var availableCount: Int? = nil
  var credits: [ResetCredit]? = nil

  func availableCredits(at date: Date = .now) -> [ResetCredit] {
    (credits ?? []).filter { credit in
      credit.status?.lowercased() == "available"
        && (credit.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) > date } ?? true)
    }
  }

  func nextAvailableCredit(at date: Date = .now) -> ResetCredit? {
    availableCredits(at: date).min {
      ($0.expiresAt ?? .max) < ($1.expiresAt ?? .max)
    }
  }
}

struct RateLimitsResponse: Codable, Equatable, Sendable {
  var accountId: String?
  var rateLimits: RateLimitBucket
  var rateLimitsByLimitId: [String: RateLimitBucket]?
  var rateLimitResetCredits: ResetCreditsSummary?

  private enum CodingKeys: String, CodingKey {
    case accountId
    case rateLimits
    case rateLimitsByLimitId
    case rateLimitResetCredits
  }

  init(
    accountId: String? = nil,
    rateLimits: RateLimitBucket = RateLimitBucket(),
    rateLimitsByLimitId: [String: RateLimitBucket]? = nil,
    rateLimitResetCredits: ResetCreditsSummary? = nil
  ) {
    self.accountId = accountId
    self.rateLimits = rateLimits
    self.rateLimitsByLimitId = rateLimitsByLimitId
    self.rateLimitResetCredits = rateLimitResetCredits
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountId = try? container.decodeIfPresent(String.self, forKey: .accountId)
    rateLimits =
      (try? container.decodeIfPresent(RateLimitBucket.self, forKey: .rateLimits))
      ?? RateLimitBucket()
    rateLimitsByLimitId =
      try? container.decodeIfPresent([String: RateLimitBucket].self, forKey: .rateLimitsByLimitId)
    rateLimitResetCredits =
      try? container.decodeIfPresent(ResetCreditsSummary.self, forKey: .rateLimitResetCredits)
  }

  var buckets: [RateLimitBucket] {
    if let values = rateLimitsByLimitId, !values.isEmpty {
      return values.map { key, value in
        var bucket = value
        if bucket.limitId?.nilIfEmpty == nil { bucket.limitId = key }
        return bucket
      }.sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
    }
    return [rateLimits]
  }
}

struct TokenUsageSummary: Codable, Equatable, Sendable {
  var lifetimeTokens: Int? = nil
  var peakDailyTokens: Int? = nil
  var longestRunningTurnSec: Int? = nil
  var currentStreakDays: Int? = nil
  var longestStreakDays: Int? = nil
}

struct DailyUsageBucket: Codable, Identifiable, Equatable, Sendable {
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

struct TokenUsageResponse: Codable, Equatable, Sendable {
  var summary: TokenUsageSummary
  var dailyUsageBuckets: [DailyUsageBucket]?

  private enum CodingKeys: String, CodingKey {
    case summary
    case dailyUsageBuckets
  }

  init(
    summary: TokenUsageSummary = TokenUsageSummary(),
    dailyUsageBuckets: [DailyUsageBucket]? = nil
  ) {
    self.summary = summary
    self.dailyUsageBuckets = dailyUsageBuckets
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary =
      (try? container.decodeIfPresent(TokenUsageSummary.self, forKey: .summary))
      ?? TokenUsageSummary()
    dailyUsageBuckets =
      try? container.decodeIfPresent([DailyUsageBucket].self, forKey: .dailyUsageBuckets)
  }
}

struct UsageSnapshot: Codable, Equatable {
  var account: CodexAccount?
  var limits: RateLimitsResponse?
  var tokenUsage: TokenUsageResponse?
  var fetchedAt: Date
}

struct HistoryPoint: Codable, Identifiable, Equatable, Sendable {
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
  case requestTimedOut(String)
  case codexHomeMismatch(expected: String, actual: String)
  case redemptionInProgress

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
    case .requestTimedOut(let method):
      return "Codex did not respond to \(method) within 20 seconds."
    case .codexHomeMismatch(let expected, let actual):
      return "Codex connected to \(actual) instead of the configured home \(expected)."
    case .redemptionInProgress:
      return "A reset credit is already being redeemed for this profile."
    }
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
