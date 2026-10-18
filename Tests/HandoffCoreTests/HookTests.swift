import Foundation
import XCTest
@testable import HandoffCore

final class HookTests: XCTestCase {
    func testOffByDefaultDoesNotWriteOrReadTranscript() throws {
        let f = try Fixture()
        XCTAssertFalse(try f.store.settings().enabled)
        let result = try ClaudeHandoffHook.handle(Data("invalid input".utf8), store: f.store, projects: f.projects)
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.root.path))
    }

    func testRateLimitQueuesOneRequestAcrossRepeatedHooks() throws {
        let f = try Fixture(); try f.enable()
        for _ in 0..<5 { try f.enqueue() }
        let all = try f.store.records()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].cwd, f.cwd.path)
        XCTAssertEqual(all[0].phase, .queued)
        let permissions = try FileManager.default.attributesOfItem(atPath: f.store.root.appendingPathComponent("records.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testOtherErrorsAndSubagentsDoNotQueue() throws {
        let f = try Fixture(); try f.enable()
        for error in ["authentication_failed", "billing_error", "overloaded", "server_error"] {
            _ = try ClaudeHandoffHook.handle(f.event(error: error), store: f.store, projects: f.projects)
        }
        _ = try ClaudeHandoffHook.handle(f.event(agentID: "subagent"), store: f.store, projects: f.projects)
        XCTAssertTrue(try f.store.records().isEmpty)
    }

    func testWarningsAreFreshAndThrottledAndNeverBlock() throws {
        let f = try Fixture(); try f.enable()
        let first = try ClaudeHandoffHook.handle(f.event("PostToolUse"), store: f.store, projects: f.projects, now: f.now)
        let specific = try XCTUnwrap(first["hookSpecificOutput"] as? [String: Any])
        XCTAssertTrue((specific["additionalContext"] as? String)?.contains("100%") == true)
        XCTAssertNil(first["decision"])
        XCTAssertNil(first["continue"])
        XCTAssertTrue(try ClaudeHandoffHook.handle(f.event("PostToolUse"), store: f.store, projects: f.projects, now: f.now).isEmpty)
        try f.store.saveUsage(HandoffUsage(checkedAt: f.now.addingTimeInterval(-181), activePercent: 100,
                                          claudeExhausted: true, explanation: "stale"))
        XCTAssertTrue(try ClaudeHandoffHook.handle(f.event("UserPromptSubmit"), store: f.store, projects: f.projects, now: f.now).isEmpty)
    }

    func testSessionStartExplainsRecoveryAndRejectsPathEscape() throws {
        let f = try Fixture(); try f.enable()
        let result = try ClaudeHandoffHook.handle(f.event("SessionStart"), store: f.store, projects: f.projects)
        XCTAssertNotNil(result["hookSpecificOutput"])
        var bad = try JSONSerialization.jsonObject(with: f.event()) as! [String: Any]
        bad["transcript_path"] = f.cwd.appendingPathComponent("secrets.jsonl").path
        XCTAssertThrowsError(try ClaudeHandoffHook.handle(JSONSerialization.data(withJSONObject: bad), store: f.store, projects: f.projects))
        bad["session_id"] = "../../settings"
        XCTAssertThrowsError(try ClaudeHandoffHook.handle(JSONSerialization.data(withJSONObject: bad), store: f.store, projects: f.projects))
    }

    func testTranscriptSymlinkOutsideClaudeIsRejected() throws {
        let f = try Fixture(); try f.enable()
        let outside = f.root.appendingPathComponent("outside.jsonl")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.removeItem(at: f.transcript)
        try FileManager.default.createSymbolicLink(at: f.transcript, withDestinationURL: outside)
        XCTAssertThrowsError(try f.enqueue())
        XCTAssertTrue(try f.store.records().isEmpty)
    }

    func testCorruptStateFailsClosed() throws {
        let f = try Fixture(); try f.enable()
        try Data("corrupt".utf8).write(to: f.store.root.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try f.enqueue())
        XCTAssertTrue(try f.store.records().isEmpty)
    }

    func testFutureUsageIsNotFresh() {
        let now = Date()
        XCTAssertFalse(HandoffUsage(checkedAt: now.addingTimeInterval(10), activePercent: 99,
                                   claudeExhausted: true, explanation: "").isFresh(at: now))
    }
}
