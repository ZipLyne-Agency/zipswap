import Foundation
import XCTest
@testable import ZipSwapCore
import HandoffCore

final class ResetOperationTests: XCTestCase {
    func testOnlyDefinitiveProtocolRejectionsResolveAnAmbiguousReset() {
        for code in [-32600, -32601, -32602] {
            XCTAssertEqual(ResetOperations.failurePhase(CodexRPCError(code: code, method: "consume")), .unavailable)
        }
        XCTAssertEqual(ResetOperations.failurePhase(CodexRPCError(code: -32603, method: "consume")), .unknown)
        XCTAssertEqual(ResetOperations.failurePhase(CancellationError()), .unknown)
    }
    func testAnAmbiguousResetSurvivesRestartAndNeverChoosesAnotherCredit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reset.json")
        var first = try ResetOperations.reserve(file, accountID: "fixture", creditID: "credit-one")
        XCTAssertNotNil(UUID(uuidString: first.key))
        first.phase = .unknown; try ResetOperations.save(first, to: file)
        let retry = try ResetOperations.reserve(file, accountID: "fixture", creditID: "credit-two")
        XCTAssertEqual(retry.key, first.key); XCTAssertEqual(retry.creditID, "credit-one")
        XCTAssertThrowsError(try ResetOperations.reserve(file, accountID: "another-account", creditID: "credit-two"))
        try ResetOperations.reconcile(file, credits: [["id": "credit-one", "status": "redeemed"]])
        XCTAssertNil(try ResetOperations.pendingCredit(file))
    }
    func testAConfirmedNonConsumptionAllowsANewLogicalAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reset.json")
        var first = try ResetOperations.reserve(file, accountID: "fixture", creditID: "credit-one")
        first.phase = .unavailable; try ResetOperations.save(first, to: file)
        let later = try ResetOperations.reserve(file, accountID: "fixture", creditID: "credit-one")
        XCTAssertNotEqual(later.key, first.key)
    }
    func testACompleteCreditInventoryCanResolveAMissingCreditWithoutClaimingConsumption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-reset-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reset.json")
        var first = try ResetOperations.reserve(file, accountID: "fixture", creditID: "credit-one")
        first.phase = .unknown; try ResetOperations.save(first, to: file)
        try ResetOperations.reconcile(file, credits: [["id": "credit-one", "status": "available"]])
        XCTAssertEqual(try ResetOperations.pendingCredit(file), "credit-one")
        try ResetOperations.reconcile(file, credits: [["id": "credit-two", "status": "available"]])
        XCTAssertNil(try ResetOperations.pendingCredit(file))
        XCTAssertEqual(try ResetOperations.read(file)?.phase, .unavailable)
        let next = try ResetOperations.reserve(file, accountID: "fixture", creditID: "credit-two")
        XCTAssertEqual(next.creditID, "credit-two")
        XCTAssertNotEqual(next.key, first.key)
    }
}
