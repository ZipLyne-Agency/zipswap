import XCTest
@testable import ZipSwapCore

final class ClaudeResetLedgerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "zipswap-ledger-test-\(UUID())"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func israel(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Jerusalem")
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: text)!
    }

    func testResetsLastThroughTheirWholeLastDayInIsraelTime() {
        var ledger = ClaudeResetLedger(defaults: defaults)
        ledger.set("horowitzisaac@gmail.com", left: 3, fable: 0, expires: ClaudeResetLedger.day("2026-12-11"))
        XCTAssertEqual(ledger.usable(for: "horowitzisaac@gmail.com", at: israel("2026-12-11T23:59:00")), 3)
        XCTAssertEqual(ledger.usable(for: "horowitzisaac@gmail.com", at: israel("2026-12-12T00:00:00")), 0)
        XCTAssertEqual(ledger.balance(for: "horowitzisaac@gmail.com")?.expires, "2026-12-11")
    }

    func testUsingCountsDownToZeroAndPersists() {
        var ledger = ClaudeResetLedger(defaults: defaults)
        ledger.set("go@ziplyne.agency", left: 1, fable: 0, expires: nil)
        XCTAssertTrue(ledger.use(.weekly, "go@ziplyne.agency"))
        XCTAssertFalse(ledger.use(.weekly, "go@ziplyne.agency"), "none left")
        XCTAssertEqual(ClaudeResetLedger(defaults: defaults).balance(for: "go@ziplyne.agency")?.left, 0)
    }

    func testExpiredResetsCannotBeUsed() {
        var ledger = ClaudeResetLedger(defaults: defaults)
        ledger.set("dev@ziplyne.agency", left: 2, fable: 1, expires: ClaudeResetLedger.day("2026-12-11"))
        XCTAssertFalse(ledger.use(.weekly, "dev@ziplyne.agency", at: israel("2026-12-12T09:00:00")))
        XCTAssertEqual(ledger.balance(for: "dev@ziplyne.agency")?.left, 2)
    }

    func testEmailsMatchRegardlessOfCaseAndCountsStayInRange() {
        var ledger = ClaudeResetLedger(defaults: defaults)
        ledger.set(" IL@Ziplyne.Agency ", left: 500, fable: 0, expires: nil)
        XCTAssertEqual(ledger.usable(for: "il@ziplyne.agency"), ClaudeResetLedger.maximum)
        ledger.set("il@ziplyne.agency", left: -4, fable: 0, expires: nil)
        XCTAssertEqual(ledger.usable(for: "il@ziplyne.agency"), 0)
        ledger.set("", left: 3, fable: 0, expires: nil)
        XCTAssertTrue(ledger.balances.keys.allSatisfy { !$0.isEmpty })
    }

    func testWeeklyAndFableResetsAreCountedApart() {
        var ledger = ClaudeResetLedger(defaults: defaults)
        ledger.set("admin@ziplyne.agency", left: 1, fable: 2, expires: nil)
        XCTAssertEqual(ledger.usable(for: "admin@ziplyne.agency"), 3)
        XCTAssertTrue(ledger.use(.fable, "admin@ziplyne.agency"))
        XCTAssertEqual(ledger.usable(.fable, for: "admin@ziplyne.agency"), 1)
        XCTAssertEqual(ledger.usable(.weekly, for: "admin@ziplyne.agency"), 1)
        ledger.set("horowitzisaac@gmail.com", left: 0, fable: 2, expires: nil)
        XCTAssertFalse(ledger.use(.weekly, "horowitzisaac@gmail.com"), "no weekly reset to spend")
        XCTAssertEqual(ClaudeResetLedger(defaults: defaults).balance(for: "horowitzisaac@gmail.com")?.fable, 2)
    }

    func testStateSavedBeforeFableResetsReadsAsWeekly() {
        defaults.set(Data(#"{"go@ziplyne.agency":{"left":1,"expires":"2026-12-11"}}"#.utf8), forKey: ClaudeResetLedger.key)
        let balance = ClaudeResetLedger(defaults: defaults).balance(for: "go@ziplyne.agency")
        XCTAssertEqual(balance, ClaudeResetBalance(left: 1, fable: 0, expires: "2026-12-11"))
    }

    func testUnreadableStoredStateStartsEmpty() {
        defaults.set(Data("not json".utf8), forKey: ClaudeResetLedger.key)
        XCTAssertTrue(ClaudeResetLedger(defaults: defaults).balances.isEmpty)
    }
}
