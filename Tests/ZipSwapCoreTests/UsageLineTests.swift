import XCTest
@testable import ZipSwapCore

final class UsageLineTests: XCTestCase {
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
