import Foundation
import XCTest
@testable import ZipSwapCore

final class CoordinationTests: XCTestCase {
    func testProviderLeaseRejectsOverlapAcrossWindowsAndIgnoresStaleCompletion() async throws {
        try await MainActor.run {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-coordination-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let one = AccountCoordinator(root: root), two = AccountCoordinator(root: root)
            let first = try one.begin(.claude, accountID: "claude-1")
            XCTAssertThrowsError(try one.begin(.claude, accountID: "claude-2"))
            XCTAssertThrowsError(try two.begin(.claude, accountID: "claude-2"))
            let otherProvider = try one.begin(.codex, accountID: "codex-test")
            one.finish(otherProvider)
            one.finish(first, verified: true)
            let next = try one.begin(.claude, accountID: "claude-2")
            one.finish(first)
            XCTAssertTrue(one.busy(.claude))
            XCTAssertGreaterThan(next.generation, first.generation)
            one.finish(next, verified: true)
            XCTAssertEqual(one.lastVerified[.claude], "claude-2")
            let crossWindow = try two.begin(.claude, accountID: "claude-3")
            two.finish(crossWindow)
        }
    }
    func testPollFanoutAndPersistentBackoffHaveAggregateBounds() throws {
        let now = Date()
        let accounts = (0..<100).map { CodexStoredAccount(id: UUID().uuidString, name: "\($0)", email: "", accountId: "\($0)", plan: "") }
        let selected = CodexPollPlan.select(accounts, liveID: "99", states: [:], now: now)
        XCTAssertEqual(selected.count, CodexPollPlan.maximumPerPass)
        XCTAssertEqual(selected.first?.accountId, "99")
        XCTAssertEqual(CodexPollPlan.maximumConcurrent, 2)
        var state = CodexPollState()
        for _ in 0..<20 { state.record(success: false, now: now) }
        XCTAssertLessThanOrEqual(try XCTUnwrap(state.retryAt).timeIntervalSince(now), 1800)
        state = try JSONDecoder().decode(CodexPollState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(state.due(at: now.addingTimeInterval(60)))
        let states = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, state) })
        XCTAssertTrue(CodexPollPlan.select(accounts, liveID: "99", states: states, now: now).isEmpty)
        state.record(success: true, now: now)
        XCTAssertEqual(state.failures, 0)
    }
    func testProgressGeometryCannotEscapeItsTrackOrLieAtZero() {
        XCTAssertEqual(UsageGeometry.fraction(0), 0)
        XCTAssertEqual(UsageGeometry.fraction(75), 0.75)
        for value in [-1.0, .nan, -.infinity] { XCTAssertEqual(UsageGeometry.fraction(value), 0) }
        XCTAssertEqual(UsageGeometry.fraction(1000), 1)
    }
    func testVersionParsingIgnoresSurroundingCLIText() {
        XCTAssertEqual(RuntimeCompatibility.version(in: "codex-cli 0.163.0"), [0,163,0])
        XCTAssertNil(RuntimeCompatibility.version(in: "unknown"))
    }
}
