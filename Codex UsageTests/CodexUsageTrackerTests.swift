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

  func testJSONLBufferPreservesSplitAndCoalescedMessages() {
    var buffer = JSONLBuffer()

    XCTAssertTrue(buffer.append(Data(#"{"id":1,"res"#.utf8)).isEmpty)
    let middle = buffer.append(Data("ult\":{\"ok\":true}}\n{\"method\":\"notice\"".utf8))
    let final = buffer.append(Data("}\n".utf8))

    XCTAssertEqual(
      middle.map { String(decoding: $0, as: UTF8.self) },
      [#"{"id":1,"result":{"ok":true}}"#])
    XCTAssertEqual(
      final.map { String(decoding: $0, as: UTF8.self) },
      [#"{"method":"notice"}"#])
  }

  func testResponseShapeExcludesNotificationsAndServerRequests() throws {
    let response = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(#"{"id":4,"result":{}}"#.utf8))
        as? [String: Any])
    let notification = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(#"{"method":"notice","params":{}}"#.utf8))
        as? [String: Any])
    let serverRequest = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(#"{"id":4,"method":"approval/request","params":{}}"#.utf8))
        as? [String: Any])

    XCTAssertTrue(CodexAppServerClient.isResponse(response))
    XCTAssertFalse(CodexAppServerClient.isResponse(notification))
    XCTAssertFalse(CodexAppServerClient.isResponse(serverRequest))
  }

  func testSparseBucketMergeRetainsCachedFields() {
    let old = RateLimitBucket(
      limitId: "codex",
      limitName: "Codex",
      primary: RateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: 100),
      secondary: RateLimitWindow(usedPercent: 20, windowDurationMins: 10_080, resetsAt: 200),
      credits: CreditSnapshot(hasCredits: true, unlimited: false, balance: "$5"),
      individualLimit: SpendControlLimitSnapshot(
        limit: "$100", used: "$25", remainingPercent: 75, resetsAt: 300))
    let update = RateLimitBucket(
      limitId: "codex",
      primary: RateLimitWindow(usedPercent: 55, windowDurationMins: nil, resetsAt: nil))

    let merged = UsageStore.merged(old: old, new: update)

    XCTAssertEqual(merged.primary?.usedPercent, 55)
    XCTAssertEqual(merged.secondary, old.secondary)
    XCTAssertEqual(merged.credits, old.credits)
    XCTAssertEqual(merged.individualLimit, old.individualLimit)
    XCTAssertEqual(merged.limitName, "Codex")
  }

  func testUnknownLiveBucketLeavesMultiBucketCacheUntouched() {
    let cached = RateLimitsResponse(
      rateLimits: RateLimitBucket(limitId: "codex"),
      rateLimitsByLimitId: [
        "codex": RateLimitBucket(
          limitId: "codex",
          primary: RateLimitWindow(usedPercent: 10, windowDurationMins: nil, resetsAt: nil)),
        "review": RateLimitBucket(
          limitId: "review",
          primary: RateLimitWindow(usedPercent: 20, windowDurationMins: nil, resetsAt: nil)),
      ])
    let unknown = RateLimitBucket(
      limitId: "future-limit",
      primary: RateLimitWindow(usedPercent: 30, windowDurationMins: nil, resetsAt: nil))

    XCTAssertNil(UsageStore.mergingLiveBucket(unknown, into: cached))
    XCTAssertEqual(cached.buckets.map(\.id), ["codex", "review"])
  }

  func testCodexHomeComparisonFallsBackToCaseInsensitivePaths() {
    XCTAssertTrue(
      CodexAppServerClient.sameDirectory(
        "/private/tmp/Codex-Usage-Nonexistent",
        "/private/tmp/codex-usage-nonexistent"))
  }

  func testNVMVersionsSortNumerically() {
    let versions = ["v9.0.0", "v20.1.0", "v10.12.0"].sorted {
      CodexAppServerClient.nvmVersionIsNewer($0, than: $1)
    }

    XCTAssertEqual(versions, ["v20.1.0", "v10.12.0", "v9.0.0"])
  }

  func testMapKeysProvideStableBucketIdentity() throws {
    let data = Data(
      #"""
      {
        "rateLimits": {},
        "rateLimitsByLimitId": {
          "codex": { "primary": { "usedPercent": 10 } },
          "review": { "primary": { "usedPercent": 20 } }
        }
      }
      """#.utf8)

    let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)

    XCTAssertEqual(response.buckets.map(\.id), ["codex", "review"])
  }

  func testRateLimitsDecodeSurvivesMalformedOptionalSubobject() throws {
    let data = Data(
      #"""
      {
        "unknownFutureField": true,
        "rateLimits": {
          "limitId": "codex",
          "primary": { "usedPercent": 42 },
          "individualLimit": {
            "limit": 100,
            "used": "$35",
            "remainingPercent": 65,
            "resetsAt": 1770000000
          }
        }
      }
      """#.utf8)

    let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)

    XCTAssertEqual(response.rateLimits.primary?.usedPercent, 42)
    XCTAssertNil(response.rateLimits.individualLimit)
  }

  func testTerminalLauncherRefusesToOverwriteUnownedFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = CodexProfile(
      id: UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!,
      name: "Work Account")
    let launcher = TerminalLauncherService.launcherURL(for: profile, baseDirectory: directory)
    try "user-owned file".write(to: launcher, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try TerminalLauncherService.install(
        for: profile,
        baseDirectory: directory,
        executableURL: URL(fileURLWithPath: "/usr/bin/true"))
    ) { error in
      XCTAssertEqual(error as? TerminalLauncherError, .unsafeExistingFile)
    }
    XCTAssertEqual(try String(contentsOf: launcher, encoding: .utf8), "user-owned file")
  }

  func testCSVFieldsAreQuotedAndFormulaGuarded() {
    XCTAssertEqual(HistoryStore.csvField("codex,review"), #""codex,review""#)
    XCTAssertEqual(HistoryStore.csvField("=HYPERLINK(\"bad\")"), #""'=HYPERLINK(""bad"")""#)
  }

  func testHistoryDownsamplesRapidRefreshes() {
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(HistoryStore.shouldRecord(lastDate: nil, now: now))
    XCTAssertFalse(
      HistoryStore.shouldRecord(
        lastDate: now.addingTimeInterval(-60),
        now: now))
    XCTAssertTrue(
      HistoryStore.shouldRecord(
        lastDate: now.addingTimeInterval(-301),
        now: now))
  }

  func testResetCreditSelectionUsesStatusExpiryAndSoonestExpiry() {
    let now = Date(timeIntervalSince1970: 1_000)
    let summary = ResetCreditsSummary(
      availableCount: 3,
      credits: [
        ResetCredit(id: "redeemed", status: "redeemed", expiresAt: 1_500),
        ResetCredit(id: "expired", status: "available", expiresAt: 900),
        ResetCredit(id: "later", status: "available", expiresAt: 2_000),
        ResetCredit(id: "sooner", status: "AVAILABLE", expiresAt: 1_500),
      ])

    XCTAssertEqual(summary.availableCredits(at: now).compactMap(\.id), ["later", "sooner"])
    XCTAssertEqual(summary.nextAvailableCredit(at: now)?.id, "sooner")
  }
}
