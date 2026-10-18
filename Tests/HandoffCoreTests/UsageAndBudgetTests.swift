import Foundation
import XCTest
@testable import HandoffCore

final class UsageAndBudgetTests: XCTestCase {
    func account(_ percent: Double?, active: Bool = false, disabled: Bool = false,
                 healthy: Bool = true, age: TimeInterval = 0, now: Date) -> HandoffAccountUsage {
        HandoffAccountUsage(active: active, disabled: disabled, percent: percent, blocked: percent == 100,
                            healthy: healthy, fetchedAt: now.addingTimeInterval(-age))
    }

    func testRotationTakesPriorityAndUnknownUsageCannotAuthorize() {
        let now = Date()
        let full = account(100, active: true, now: now)
        for alternate in [account(20, now: now), account(96, now: now), account(nil, now: now), account(100, healthy: false, now: now),
                          account(100, age: 181, now: now), account(.nan, now: now)] {
            XCTAssertFalse(HandoffUsagePolicy.evaluate([full, alternate], rotationEnabled: true, now: now).claudeExhausted)
        }
        XCTAssertFalse(HandoffUsagePolicy.evaluate([], rotationEnabled: true, now: now).claudeExhausted)
        XCTAssertFalse(HandoffUsagePolicy.evaluate([account(100, now: now)], rotationEnabled: true, now: now).claudeExhausted)
        XCTAssertFalse(HandoffUsagePolicy.evaluate([account(96, active: true, now: now), account(100, now: now)], rotationEnabled: true, now: now).claudeExhausted)
        XCTAssertTrue(HandoffUsagePolicy.evaluate([full, account(100, now: now)], rotationEnabled: true, now: now).claudeExhausted)
    }

    func testOnlyEligibleAccountsCountAndActiveCannotBeExcluded() {
        let now = Date()
        let full = account(99, active: true, now: now)
        let spare = account(20, now: now)
        XCTAssertTrue(HandoffUsagePolicy.evaluate([full, spare], rotationEnabled: false, now: now).claudeExhausted)
        XCTAssertTrue(HandoffUsagePolicy.evaluate([full, account(20, disabled: true, now: now)], rotationEnabled: true, now: now).claudeExhausted)
        XCTAssertFalse(HandoffUsagePolicy.evaluate([account(20, active: true, disabled: true, now: now), account(100, now: now)], rotationEnabled: true, now: now).claudeExhausted)
    }

    func testFourPreparationsPerHourSurviveRestartAndReopen() throws {
        let f = try Fixture(); try f.enable()
        for i in 0..<5 {
            let id = UUID().uuidString.lowercased()
            let input = ClaudeHookInput(sessionID: id, transcriptPath: f.transcript.path, cwd: f.cwd.path,
                                       event: "StopFailure", error: "rate_limit", agentID: nil)
            XCTAssertTrue(try f.store.enqueue(input, now: f.now))
            let store = HandoffStore(root: f.store.root)
            XCTAssertEqual(try store.claim(id, now: f.now), i < 4)
            if i < 4 { try store.update(id) { $0.phase = .failed } }
        }
        XCTAssertEqual(try f.store.records().filter { $0.attemptedAt != nil }.count, 4)
    }

    func testAHealthySkipCanRecheckOnLaterEventButFailureCannot() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        try f.store.saveUsage(HandoffUsage(checkedAt: f.now, activePercent: 40, claudeExhausted: false, explanation: ""))
        let engine = HandoffEngine(store: f.store, projects: f.projects)
        _ = try engine.prepare(f.id, now: f.now, workspaceStatus: { _ in "" }, backend: { XCTFail(); return FakeBackend() })
        try f.enqueue()
        XCTAssertEqual(try f.store.record(f.id)?.phase, .skipped)
        let later = f.now.addingTimeInterval(61)
        _ = try ClaudeHandoffHook.handle(f.event(), store: f.store, projects: f.projects, now: later)
        XCTAssertEqual(try f.store.record(f.id)?.phase, .queued)
        try f.store.saveUsage(HandoffUsage(checkedAt: later, activePercent: 100, claudeExhausted: true, explanation: ""))
        let backend = FakeBackend(); backend.failAt = "preflight"
        _ = try engine.prepare(f.id, now: later, workspaceStatus: { _ in "" }, backend: { backend })
        _ = try ClaudeHandoffHook.handle(f.event(), store: f.store, projects: f.projects, now: later.addingTimeInterval(61))
        XCTAssertEqual(try f.store.record(f.id)?.phase, .failed)
    }

    func testQueueHasAggregateBound() throws {
        let f = try Fixture(); try f.enable()
        for _ in 0..<HandoffStore.maximumPending {
            XCTAssertTrue(try f.store.enqueue(ClaudeHookInput(sessionID: UUID().uuidString.lowercased(), transcriptPath: f.transcript.path,
                cwd: f.cwd.path, event: "StopFailure", error: "rate_limit", agentID: nil), now: f.now))
        }
        XCTAssertThrowsError(try f.enqueue())
        XCTAssertEqual(try f.store.records().count, HandoffStore.maximumPending)
    }
}
