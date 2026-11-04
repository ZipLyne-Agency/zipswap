import XCTest
@testable import ZipSwapCore

final class PriorityBoardTests: XCTestCase {
    private let now = Date()

    private func window(_ label: String, _ pct: Double, resetIn hours: Double = 3, exhausts: Double? = nil) -> UsageWindow {
        UsageWindow(label: label, pct: pct, resetsAt: now.addingTimeInterval(hours * 3600), expectedPct: nil,
                    projectedExhaustion: exhausts.map { now.addingTimeInterval($0 * 3600) }, willLastToReset: nil)
    }

    private func account(_ id: String, provider: Provider = .claude, active: Bool = false, problem: String? = nil,
                         _ windows: [UsageWindow]) -> Account {
        Account(id: id, provider: provider, slot: provider == .claude ? 1 : nil, name: id, email: "\(id)@example.test",
                plan: "", isActive: active, activeIdentityVerified: active, disabled: false, windows: windows,
                problem: problem, fetchedAt: now)
    }

    func testSectionsSplitActiveRunningOutUsedUpAndNotices() {
        let active = account("work", active: true, [window("5h", 40), window("Week", 75)])
        let low = account("spare", [window("5h", 10), window("Week", 82)])
        let full = account("personal", [window("5h", 0), window("Week", 100, resetIn: 30)])
        let broken = account("old", problem: "Login expired", [])
        let pending = account("fresh", [])
        let board = PriorityBoard.make(claude: [active, low, full, broken, pending], codex: [], upNext: { _ in nil }, now: now)

        XCTAssertEqual(board.inUse.map(\.id), ["work|Week"], "the active account shows its tightest limit")
        XCTAssertEqual(board.runningOut.map(\.id), ["spare|Week"])
        XCTAssertEqual(board.usedUp.map(\.id), ["personal|Week"])
        XCTAssertEqual(board.notices.map(\.id), ["old"])
        XCTAssertEqual(board.waiting.map(\.id), ["fresh"])
        XCTAssertFalse(board.allClear)
    }

    func testAnAccountNotPolledYetWaitsInsteadOfNeedingAttention() {
        let unpolled = account("cx", provider: .codex, problem: Account.awaitingFirstReading, [])
        let failed = account("old", provider: .codex, problem: "Sign-in expired", [])
        let board = PriorityBoard.make(claude: [], codex: [unpolled, failed], upNext: { _ in nil }, now: now)
        XCTAssertEqual(board.waiting.map(\.id), ["cx"])
        XCTAssertEqual(board.notices.map(\.id), ["old"])
    }

    func testRunningOutRanksByRunwayThenByWhatIsLeft() {
        let slow = account("slow", [window("Week", 72)])
        let soon = account("soon", [window("Week", 71, exhausts: 2)])
        let lowest = account("lowest", [window("Week", 88)])
        let board = PriorityBoard.make(claude: [slow, soon, lowest], codex: [], upNext: { _ in nil }, now: now)
        XCTAssertEqual(board.runningOut.map(\.account.id), ["soon", "lowest", "slow"])
    }

    func testUsedUpUsesTheLimitThatKeepsTheAccountOutLongest() {
        let full = account("both", [window("5h", 100, resetIn: 1), window("Week", 100, resetIn: 48)])
        let board = PriorityBoard.make(claude: [full], codex: [], upNext: { _ in nil }, now: now)
        XCTAssertEqual(board.usedUp.map(\.window.label), ["Week"])
    }

    func testAllClearNeedsEveryAccountReportedAndNothingLow() {
        let active = account("work", active: true, [window("5h", 20), window("Week", 30)])
        let spare = account("spare", [window("Week", 10)])
        XCTAssertTrue(PriorityBoard.make(claude: [active, spare], codex: [], upNext: { _ in nil }, now: now).allClear)
        let waiting = account("new", [])
        XCTAssertFalse(PriorityBoard.make(claude: [active, waiting], codex: [], upNext: { _ in nil }, now: now).allClear)
        let hot = account("work", active: true, [window("Week", 91)])
        XCTAssertFalse(PriorityBoard.make(claude: [hot], codex: [], upNext: { _ in nil }, now: now).allClear)
    }

    func testUpNextComesFromTheModelPerProvider() {
        let spare = account("spare", [window("Week", 10)])
        let codex = account("cx", provider: .codex, [window("Week", 5)])
        let board = PriorityBoard.make(claude: [spare], codex: [codex], upNext: { $0 == .claude ? spare : codex }, now: now)
        XCTAssertEqual(board.upNext.map(\.id), ["spare", "cx"])
    }

    func testLabelsReadAsTheDesignNamesThem() {
        XCTAssertEqual(UsageLine.title(for: "5h"), "Session")
        XCTAssertEqual(UsageLine.title(for: "Week"), "Weekly")
        XCTAssertEqual(UsageLine.title(for: "fable"), "Fable")
    }

    func testLowLimitAlertOnlyWhenNothingWillTakeOver() {
        let hot = account("work", active: true, [window("5h", 20), window("Week", 93)])
        let spare = account("spare", [window("Week", 10)])
        XCTAssertNil(LowLimitAlert.alert(active: hot, upNext: spare, autoSwitchOn: true, now: now), "auto-switch will move on")
        let alone = LowLimitAlert.alert(active: hot, upNext: nil, autoSwitchOn: true, now: now)
        XCTAssertEqual(alone?.title, "Work has 7% left")
        XCTAssertTrue(alone?.body.contains("No other Claude Code account is ready") ?? false)
        let manual = LowLimitAlert.alert(active: hot, upNext: spare, autoSwitchOn: false, now: now)
        XCTAssertTrue(manual?.body.contains("Switch to Spare") ?? false)
        XCTAssertEqual(alone?.key, manual?.key, "one alert per limit window")
        let calm = account("work", active: true, [window("Week", 80)])
        XCTAssertNil(LowLimitAlert.alert(active: calm, upNext: nil, autoSwitchOn: true, now: now))
        let full = account("work", active: true, [window("Week", 100)])
        XCTAssertNil(LowLimitAlert.alert(active: full, upNext: nil, autoSwitchOn: true, now: now), "a used-up account is shown as Used Up, not warned")
    }
}
