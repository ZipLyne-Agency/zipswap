import XCTest
@testable import ZipSwapCore

final class ClaudeSafetyNetTests: XCTestCase {
    private let now = Date()

    private func account(_ id: String, slot: Int, active: Bool = false, week: Double, fiveHour: Double? = nil,
                         age: TimeInterval = 60, status: String = "ok", problem: String? = nil,
                         stale: Bool = false, disabled: Bool = false, limited429: Bool? = nil) -> Account {
        var windows = [UsageWindow(label: "Week", pct: week, resetsAt: now.addingTimeInterval(3 * 86_400), expectedPct: nil,
                                   projectedExhaustion: nil, willLastToReset: nil, windowMinutes: 10_080)]
        if let fiveHour {
            windows.insert(UsageWindow(label: "5h", pct: fiveHour, resetsAt: now.addingTimeInterval(3600), expectedPct: nil,
                                       projectedExhaustion: nil, willLastToReset: nil, windowMinutes: 300), at: 0)
        }
        var account = Account(id: id, provider: .claude, slot: slot, name: id, email: "\(id)@example.test", plan: "",
                              isActive: active, activeIdentityVerified: active, disabled: disabled, windows: windows,
                              problem: problem, fetchedAt: now.addingTimeInterval(-age), stale: stale, usageStatus: status)
        // claude-swap's 429 history: by default a 429 a minute after the reading (the logged pattern).
        account.rateLimitKnown = true
        if limited429 ?? active { account.rateLimitedAt = now.addingTimeInterval(-age + 60) }
        return account
    }

    private func input(_ accounts: [Account], line: Double = 99, engine: Bool = true, reported: Date? = nil,
                       blockedSince: Date? = nil, left: [String: Date] = [:]) -> ClaudeSafetyNet.Input {
        .init(accounts: accounts, line: line, engineRunning: engine, limitReportedAt: reported,
              blockedSince: blockedSince, left: left, now: now)
    }

    /// The fleet as logged on 11 November 2026 (99% line, Fable watched).
    private func fleet(active: Account) -> [Account] {
        [account("ziplyne", slot: 1, week: 100), account("personal", slot: 2, week: 99, age: 400),
         account("admin", slot: 3, week: 100), active,
         account("go", slot: 5, week: 80, age: 500), account("dev", slot: 6, week: 44, age: 300)]
    }

    func testLoggedIncidentsFrozenBelowTheLineDuringA429Switch() {
        // Each switch on 9–11 Nov came 6–120 minutes after a 429 froze the
        // active reading under 99%. The reading's age is the only visible sign;
        // the last good read came a minute before the 429 (urgent cadence).
        for (frozen, minutes) in [(96.0, 23.0), (97.0, 21.0), (93.0, 17.0), (98.0, 6.0), (95.0, 120.0)] {
            let il = account("il", slot: 4, active: true, week: frozen, fiveHour: frozen, age: (minutes + 1) * 60)
            XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .switchTo(id: "dev", trigger: .blind),
                           "frozen at \(frozen)% for \(minutes) min")
        }
    }

    func testAFrozenReadingIsAlsoBlindWhenTheHelperMarksItUnavailable() {
        let il = account("il", slot: 4, active: true, week: 97, age: 900, status: "unavailable", problem: "Usage throttled", stale: true)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .switchTo(id: "dev", trigger: .blind))
    }

    func testFreshOrFarFromTheLineReadingsStay() {
        let fresh = account("il", slot: 4, active: true, week: 97, age: 90)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: fresh))), .stay, "the engine owns a fresh reading")
        let slowCadence = account("il", slot: 4, active: true, week: 97, age: 330)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: slowCadence))), .stay, "the engine's slowest normal read")
        let far = account("il", slot: 4, active: true, week: 60, age: 1800)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: far))), .stay, "an idle account far from its line")
        let justUnder = account("il", slot: 4, active: true, week: 83, age: 1800)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: justUnder))), .stay, "outside the 15-point band")
    }

    func testLoginProblemsAndIdleExpiredTokensAreLeftToTheEngine() {
        for status in ["token_expired", "relogin_required", "foreign_credential", "keychain_unavailable"] {
            let il = account("il", slot: 4, active: true, week: 97, age: 1800, status: status, problem: "Login")
            XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .stay, status)
        }
    }

    func testNoTargetIsReportedNotSilent() {
        let il = account("il", slot: 4, active: true, week: 97, age: 1200)
        let used = [account("a", slot: 1, week: 100), il, account("b", slot: 2, week: 99.5, fiveHour: 100)]
        XCTAssertEqual(ClaudeSafetyNet.decide(input(used)), .noTarget(trigger: .blind))
    }

    func testCandidatesNeedAUsableRecentReadingAndRoom() {
        let il = account("il", slot: 4, active: true, week: 97, age: 1200)
        let accounts = [il,
                        account("skipped", slot: 1, week: 5, disabled: true),
                        account("broken", slot: 2, week: 5, status: "relogin_required", problem: "Needs a fresh /login"),
                        account("old", slot: 3, week: 5, age: 3600),
                        account("throttled", slot: 5, week: 5, age: 600, status: "unavailable", problem: "Usage throttled", stale: true),
                        account("worse", slot: 6, week: 98)]
        XCTAssertEqual(ClaudeSafetyNet.decide(input(accounts)), .noTarget(trigger: .blind),
                       "a frozen 97% is a lower bound, so a 98% account is no improvement")
        let withRoom = accounts + [account("room", slot: 7, week: 40, age: 1400)]
        XCTAssertEqual(ClaudeSafetyNet.decide(input(withRoom)), .switchTo(id: "room", trigger: .blind))
    }

    func testAnAccountJustLeftIsNotChosenAgainUntilANewReadingShowsRoom() {
        let dev = account("dev", slot: 6, active: true, week: 96, age: 900)
        let il = account("il", slot: 4, week: 60, age: 1200)
        let leftAt = now.addingTimeInterval(-600)
        XCTAssertEqual(ClaudeSafetyNet.decide(input([il, dev], left: ["il": leftAt])), .noTarget(trigger: .blind),
                       "il's reading predates leaving it")
        let refreshed = account("il", slot: 4, week: 60, age: 60)
        XCTAssertEqual(ClaudeSafetyNet.decide(input([refreshed, dev], left: ["il": leftAt])), .switchTo(id: "il", trigger: .blind))
    }

    func testClaudeCodesLimitReportSwitchesEvenOnALowFrozenReading() {
        let il = account("il", slot: 4, active: true, week: 50, fiveHour: 70, age: 1500)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il), reported: now)), .switchTo(id: "dev", trigger: .limitReported))
        let goAndDev = [il, account("go", slot: 5, week: 80, age: 500)]
        XCTAssertEqual(ClaudeSafetyNet.decide(input(goAndDev, reported: now)), .switchTo(id: "go", trigger: .limitReported),
                       "a reported limit means the active account has nothing left, so 80% is better")
    }

    func testALimitReportAgainstAFreshReadingWithRoomIsAThrottle() {
        let il = account("il", slot: 4, active: true, week: 40, fiveHour: 30, age: 60)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il), reported: now)), .stay)
    }

    func testEngineDownSwitchesAnAccountPastItsLine() {
        let il = account("il", slot: 4, active: true, week: 99.5, age: 90)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il), engine: false)), .switchTo(id: "dev", trigger: .engineDown))
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il), engine: true)), .stay, "a running engine decides first")
    }

    func testAnAccountLeftAtItsLimitByTheEngineIsMovedAfterFiveMinutes() {
        let il = account("il", slot: 4, active: true, week: 100, age: 60)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il), blockedSince: now.addingTimeInterval(-120))), .stay)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il), blockedSince: now.addingTimeInterval(-310))),
                       .switchTo(id: "dev", trigger: .stuck))
    }

    func testPerAccountLinesAreHonored() {
        var il = account("il", slot: 4, active: true, week: 72, age: 1200)
        il.switchLine = 80
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .switchTo(id: "dev", trigger: .blind))
    }

    func testTimeoutsNetworkDropsAndSleepNearTheLineStay() {
        let il = account("il", slot: 4, active: true, week: 97, age: 1800, limited429: false)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .stay, "no 429 since the reading")
        var older429 = account("il", slot: 4, active: true, week: 97, age: 1800, limited429: false)
        older429.rateLimitedAt = now.addingTimeInterval(-7200)
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: older429))), .stay, "a 429 long before this reading")
        var timeout = account("il", slot: 4, active: true, week: 97, age: 900, status: "unavailable",
                              problem: "Usage request timed out", stale: true, limited429: false)
        timeout.usageError = "timeout"
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: timeout))), .stay)
    }

    func testWithoutClaudeSwapsHistoryOnlyAVeryOldReadingCounts() {
        var il = account("il", slot: 4, active: true, week: 97, age: 600)
        il.rateLimitKnown = false; il.rateLimitedAt = nil
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .stay)
        var older = account("il", slot: 4, active: true, week: 97, age: 960)
        older.rateLimitKnown = false; older.rateLimitedAt = nil
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: older))), .switchTo(id: "dev", trigger: .blind))
    }

    func testAnUnavailableRowNamingA429IsEvidenceEnough() {
        var il = account("il", slot: 4, active: true, week: 97, age: 400, status: "unavailable",
                         problem: "Usage throttled", stale: true, limited429: false)
        il.rateLimitKnown = false
        il.usageError = "http-429"
        XCTAssertEqual(ClaudeSafetyNet.decide(input(fleet(active: il))), .switchTo(id: "dev", trigger: .blind))
    }

    func testNextInLineIsTheAccountWithTheMostRoomThatAutoSwitchCouldUse() {
        let il = account("il", slot: 4, active: true, week: 30, age: 60)
        XCTAssertEqual(ClaudeSafetyNet.nextInLine(fleet(active: il), line: 95, now: now)?.id, "dev",
                       "a 5-minute-old reading still counts: alternates are read every 10 minutes")
        let onlyFull = [il, account("a", slot: 1, week: 100), account("b", slot: 2, week: 96)]
        XCTAssertNil(ClaudeSafetyNet.nextInLine(onlyFull, line: 95, now: now), "over its line is not next")
    }

    /// Real `claude-swap list --json` rows (schema 1) and its usage cache, through
    /// ZipSwap's own parser: the frozen active row arrives as "ok" with an old
    /// `usageFetchedAt`, alternates as "ok" up to their ten-minute read.
    func testRealHelperRowsAndCacheReachTheSameDecision() throws {
        let iso = ISO8601DateFormatter()
        func row(_ number: Int, _ name: String, active: Bool, week: Double, fiveHour: Double, fable: Double, age: TimeInterval) -> [String: Any] {
            let reset = iso.string(from: now.addingTimeInterval(86_400))
            return ["number": number, "email": "\(name)@example.test", "alias": name, "organizationName": "Org", "organizationUuid": "org-\(number)",
                    "isOrganization": true, "active": active, "usageStatus": "ok",
                    "usage": ["fiveHour": ["pct": fiveHour, "resetsAt": reset], "sevenDay": ["pct": week, "resetsAt": reset],
                              "scoped": [["pct": fable, "resetsAt": reset, "name": "Fable"]]],
                    "usageFetchedAt": iso.string(from: now.addingTimeInterval(-age)), "usageAgeSeconds": age]
        }
        let json: [String: Any] = ["schemaVersion": 1, "activeAccountNumber": 4, "accounts": [
            row(4, "il", active: true, week: 69, fiveHour: 96, fable: 28, age: 1260),
            row(5, "go", active: false, week: 80, fiveHour: 0, fable: 31, age: 500),
            row(6, "dev", active: false, week: 44, fiveHour: 0, fable: 30, age: 560)]]
        var accounts = try ClaudeService.decode(ShellResult(status: 0, stdout: JSONSerialization.data(withJSONObject: json), stderr: Data()))

        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-usage-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: cache) }
        let usage: [String: Any] = ["accounts": [
            "4": ["email": "il@example.test", "last429At": now.addingTimeInterval(-1200).timeIntervalSince1970],
            "6": ["email": "dev@example.test", "last429At": NSNull()]]]
        try JSONSerialization.data(withJSONObject: usage).write(to: cache)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        let limited = try XCTUnwrap(ClaudeService.rateLimitTimes(at: cache))
        accounts = accounts.map { var account = $0; account.rateLimitedAt = limited[account.email.lowercased()]; account.rateLimitKnown = true; return account }

        XCTAssertEqual(accounts.first(where: \.isActive)?.usageStatus, "ok")
        XCTAssertEqual(ClaudeSafetyNet.decide(input(accounts)), .switchTo(id: "claude-6", trigger: .blind))
        XCTAssertNil(ClaudeService.rateLimitTimes(at: cache.appendingPathExtension("missing")), "unreadable history is unknown, not empty")
    }
}
