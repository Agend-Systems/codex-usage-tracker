import Foundation
import XCTest

@testable import Codex_Usage

final class CodexUsageTrackerTests: XCTestCase {
  func testDecodesChatGPTAccountWithoutReadingCredentials() throws {
    let data = Data(#"{"type":"chatgpt","email":"developer@example.com","planType":"plus"}"#.utf8)

    let account = try JSONDecoder().decode(CodexAccount.self, from: data)

    XCTAssertEqual(account.kind, .chatgpt)
    XCTAssertEqual(account.email, "developer@example.com")
    XCTAssertEqual(account.planType, "plus")
  }

  func testDecodesCurrentRateLimitShapeAndSortsBuckets() throws {
    let data = Data(
      #"""
      {
        "accountId": "account-1",
        "rateLimits": {
          "limitId": "codex",
          "primary": { "usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1770000000 },
          "individualLimit": { "limit": "$100", "used": "$35", "remainingPercent": 65, "resetsAt": 1770000000 }
        },
        "rateLimitsByLimitId": {
          "zeta": { "limitId": "zeta", "limitName": "Zeta", "primary": { "usedPercent": 10 } },
          "codex": { "limitId": "codex", "limitName": "Codex", "secondary": { "usedPercent": 63 } }
        },
        "rateLimitResetCredits": { "availableCount": 1, "credits": [] }
      }
      """#.utf8)

    let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)

    XCTAssertEqual(response.buckets.map(\.id), ["codex", "zeta"])
    XCTAssertEqual(response.rateLimits.primary?.usedPercent, 42)
    XCTAssertEqual(response.rateLimits.individualLimit?.usedPercent, 35)
    XCTAssertEqual(response.rateLimitResetCredits?.availableCount, 1)
  }

  func testDecodesTokenUsageSummaryAndDailyBuckets() throws {
    let data = Data(
      #"""
      {
        "summary": {
          "lifetimeTokens": 120000,
          "peakDailyTokens": 24000,
          "longestRunningTurnSec": 87,
          "currentStreakDays": 4,
          "longestStreakDays": 9
        },
        "dailyUsageBuckets": [{ "startDate": "2026-09-09", "tokens": 3200 }]
      }
      """#.utf8)

    let usage = try JSONDecoder().decode(TokenUsageResponse.self, from: data)

    XCTAssertEqual(usage.summary.lifetimeTokens, 120000)
    XCTAssertEqual(usage.dailyUsageBuckets?.first?.tokens, 3200)
    XCTAssertNotNil(usage.dailyUsageBuckets?.first?.date)
  }

  func testWindowLabelsAndRemainingPercentage() {
    XCTAssertEqual(
      RateLimitWindow(usedPercent: 72, windowDurationMins: 300, resetsAt: nil).durationLabel,
      "5-hour rolling window")
    XCTAssertEqual(
      RateLimitWindow(usedPercent: 72, windowDurationMins: 10_080, resetsAt: nil).durationLabel,
      "1-week rolling window")
    XCTAssertEqual(
      RateLimitWindow(usedPercent: 72, windowDurationMins: 300, resetsAt: nil).remainingPercent, 28)
  }

  func testTerminalLauncherUsesSafeSlug() {
    XCTAssertEqual(TerminalLauncherService.slug(for: "Work & Research"), "work-research")
    XCTAssertEqual(TerminalLauncherService.slug(for: "  "), "profile")
  }
}
