import XCTest
@testable import ZipSwapCore
import HandoffCore

final class AccountValidationTests: XCTestCase {
    private func decode(_ rows: [[String: Any]]) throws -> [Account] {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "accounts": rows])
        return try ClaudeService.decode(ShellResult(status: 0, stdout: data, stderr: Data()))
    }
    func testMalformedClaudeRowsCannotReachDuplicateIDs() {
        XCTAssertThrowsError(try decode([[:], [:]]))
        let row: [String: Any] = ["number": 1, "email": "one@example.test", "active": false, "usageStatus": "unavailable"]
        XCTAssertThrowsError(try decode([row, row]))
        var invalid = row; invalid["usage"] = ["sevenDay": ["pct": 101.0]]
        XCTAssertThrowsError(try decode([invalid]))
        invalid["usage"] = ["sevenDay": ["pct": 42.0, "resetsAt": "nonsense"]]
        XCTAssertThrowsError(try decode([invalid]))
    }
    func testUnknownUsageDoesNotAuthorizeSelection() {
        let stored = CodexStoredAccount(id: UUID().uuidString, name: "Fake", email: "", accountId: "account-one", plan: "pro")
        for limits in [[:], ["ordinaryUsageAllowed": NSNull(), "rateLimits": ["primary": ["usedPercent": 2.0, "windowDurationMins": 300]]]] as [[String: Any]] {
            let account = CodexService.parse(stored, isActive: false, account: nil, limits: limits, error: nil)
            XCTAssertNotNil(account.eligibilityReason())
        }
    }
    func testUsageExpiryIsSeparateFromRefreshAttempt() {
        let now = Date()
        var account = ClaudeService.parse(["number": 1, "usageStatus": "ok", "usageFetchedAt": now.timeIntervalSince1970,
                                          "usage": ["sevenDay": ["pct": 42.0]]])
        XCTAssertTrue(account.readingTrusted(at: now))
        XCTAssertFalse(account.readingTrusted(at: now.addingTimeInterval(181)))
        account.stale = true
        XCTAssertFalse(account.readingTrusted(at: now))
    }
    func testSerializedFractionalTimestampsDoNotInventFutureReadings() {
        for index in 0..<16 {
            let now = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index) / 8_388_608)
            let account = ClaudeService.parse(["number": 1, "usageStatus": "ok", "usageFetchedAt": now.timeIntervalSince1970,
                                              "usage": ["sevenDay": ["pct": 42.0]]])
            XCTAssertTrue(account.readingTrusted(at: now), "A timestamp round trip must remain fresh (sample \(index))")
            XCTAssertFalse(account.readingTrusted(at: now.addingTimeInterval(-0.001)), "A genuinely future reading must remain untrusted")
        }
    }
    func testExhaustionTrustCannotCrossReset() {
        let now = Date()
        let reset = now.addingTimeInterval(400)
        let expiry = UsageValidity.trustUntil(fetchedAt: now, exhausted: true, reset: reset)
        XCTAssertEqual(expiry, reset)
        XCTAssertTrue(UsageValidity.isTrusted(fetchedAt: now, until: expiry, now: now.addingTimeInterval(300)))
        XCTAssertFalse(UsageValidity.isTrusted(fetchedAt: now, until: expiry, now: reset.addingTimeInterval(1)))
    }
    func testCachedRefreshKeepsMeasurementAgeAndExplainsProviderWait() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let row: [String: Any] = ["number": 1, "usageStatus": "ok", "usageFetchedAt": fetched.timeIntervalSince1970,
                                 "usage": ["sevenDay": ["pct": 42.0]]]
        let fresh = ClaudeService.parse(row)
        XCTAssertFalse(fresh.usageFreshness(now: fetched).contains("Awaiting provider update"))
        // Re-reading the helper cache is not a new provider measurement.
        var reread = ClaudeService.parse(row)
        let later = fetched.addingTimeInterval(240)
        XCTAssertEqual(reread.fetchedAt, fetched)
        XCTAssertFalse(reread.readingTrusted(at: later))
        XCTAssertTrue(reread.usageFreshness(now: later).contains("Awaiting provider update"))
        XCTAssertFalse(reread.usageFreshness(now: later).contains("Refresh needed"))
        reread.stale = true
        XCTAssertTrue(reread.usageFreshness(now: later).contains("Awaiting provider update"))
    }
    func testWatchOnlyAppliesRelevantModelWindows() {
        let account = ClaudeService.parse(["number": 1, "usageStatus": "ok", "usageFetchedAt": Date().timeIntervalSince1970,
            "usage": ["sevenDay": ["pct": 20.0], "scoped": [["name": "Other", "pct": 100.0]]]])
        XCTAssertFalse(account.isBlocked)
        var watched = account; watched.watchedModels = ["other"]
        XCTAssertTrue(watched.isBlocked)
    }
    func testInvalidPercentFormattingNeverTraps() {
        XCTAssertEqual(Format.pct(.nan), "Unknown")
        XCTAssertEqual(Format.pct(.infinity), "Unknown")
        XCTAssertEqual(Format.pct(1e100), "Unknown")
    }
    func testManualChoiceCanUseAnOlderKnownReadingWithoutAuthorizingAutomaticSelection() {
        var account = ClaudeService.parse(["number": 1, "usageStatus": "ok", "usageFetchedAt": Date().addingTimeInterval(-600).timeIntervalSince1970,
                                           "usage": ["sevenDay": ["pct": 42.0]]])
        XCTAssertNil(account.manualSwitchReason())
        XCTAssertNotNil(account.eligibilityReason())
        account.problem = "Login expired"
        XCTAssertEqual(account.manualSwitchReason(), "Login expired")
        let full = ClaudeService.parse(["number": 2, "usageStatus": "ok", "usage": ["sevenDay": ["pct": 100.0]]])
        XCTAssertNotNil(full.manualSwitchReason())
        XCTAssertNotNil(ClaudeService.parse(["number": 3, "usageStatus": "unavailable"]).manualSwitchReason())
    }
    func testModelSpecificCodexExhaustionBlocksAnOtherwiseAvailableAccount() throws {
        var limits: [String: Any] = ["accountId": "fixture", "ordinaryUsageAllowed": true,
                                    "rateLimits": ["primary": ["usedPercent": 12, "windowDurationMins": 300]],
                                    "rateLimitsByLimitId": ["model-special": ["limitName": "Special", "primary": ["usedPercent": 100, "windowDurationMins": 10080]]]]
        let snapshot = try CodexUsageSnapshot(limits, expectedAccountID: "fixture")
        XCTAssertTrue(snapshot.reached)
        XCTAssertEqual(snapshot.windows.first(where: { $0.scope == "Special" })?.used, 100)
        limits["rateLimitsByLimitId"] = ["broken": "invalid"]
        XCTAssertThrowsError(try CodexUsageSnapshot(limits, expectedAccountID: "fixture"))
    }
}
