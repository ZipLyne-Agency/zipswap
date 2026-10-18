import Foundation
import XCTest
@testable import HandoffCore

final class EngineTests: XCTestCase {
    func testFullTransferAndDuplicateEventNeverCreatesSecondThread() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        let backend = FakeBackend()
        let engine = HandoffEngine(store: f.store, projects: f.projects)
        let record = try XCTUnwrap(engine.prepare(f.id, now: f.now, workspaceStatus: { _ in " M Widget.swift" }, backend: { backend }))
        XCTAssertEqual(record.phase, .ready)
        XCTAssertEqual(record.threadID, backend.threadID)
        XCTAssertTrue(record.canOpen)
        XCTAssertTrue(backend.context.contains("ORCHID-742"))
        XCTAssertTrue(backend.context.contains("Do not deploy"))
        XCTAssertTrue(backend.context.contains(" M Widget.swift"))
        XCTAssertEqual(backend.calls, ["preflight", "create", "inject", "name", "verify", "close"])
        try f.enqueue()
        _ = try engine.prepare(f.id, now: f.now, workspaceStatus: { _ in "" }, backend: { XCTFail("Duplicate backend"); return backend })
        XCTAssertEqual(backend.calls.filter { $0 == "create" }.count, 1)
    }

    func testFailureAfterCreationKeepsIDButCannotOpenOrRetry() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        let backend = FakeBackend(); backend.failAt = "inject"
        let engine = HandoffEngine(store: f.store, projects: f.projects)
        let result = try XCTUnwrap(engine.prepare(f.id, now: f.now, workspaceStatus: { _ in "" }, backend: { backend }))
        XCTAssertEqual(result.phase, .failed)
        XCTAssertEqual(result.threadID, backend.threadID)
        XCTAssertFalse(result.canOpen)
        XCTAssertEqual(backend.calls.last, "close")
        _ = try engine.prepare(f.id, now: f.now, workspaceStatus: { _ in "" }, backend: { XCTFail("Must not retry"); return backend })
        XCTAssertThrowsError(try HandoffCommands.resumeArguments(result, initial: true))
    }

    func testAvailableClaudeOrStaleUsageMakesZeroCodexCalls() throws {
        for stale in [false, true] {
            let f = try Fixture(); try f.enable(); try f.enqueue()
            try f.store.saveUsage(HandoffUsage(checkedAt: stale ? f.now.addingTimeInterval(-181) : f.now,
                                              activePercent: 100, claudeExhausted: stale, explanation: ""))
            let result = try HandoffEngine(store: f.store, projects: f.projects).prepare(f.id, now: f.now,
                workspaceStatus: { _ in XCTFail("Must not inspect workspace"); return "" },
                backend: { XCTFail("Must not start Codex"); return FakeBackend() })
            XCTAssertEqual(result?.phase, .skipped)
        }
    }

    func testTurningOffDuringPreparationStopsBeforeCreate() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        let backend = FakeBackend()
        backend.onPreflight = { var s = try f.store.settings(); s.enabled = false; try f.store.saveSettings(s) }
        let result = try HandoffEngine(store: f.store, projects: f.projects).prepare(f.id, now: f.now, workspaceStatus: { _ in "" }, backend: { backend })
        XCTAssertEqual(result?.phase, .failed)
        XCTAssertFalse(backend.calls.contains("create"))
        XCTAssertEqual(backend.calls.last, "close")
    }

    func testInterruptedReservationIsTerminal() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        XCTAssertTrue(try f.store.claim(f.id, now: f.now))
        XCTAssertFalse(try f.store.claim(f.id, now: f.now))
        try f.store.recoverInterrupted(now: f.now.addingTimeInterval(121))
        XCTAssertEqual(try f.store.record(f.id)?.phase, .failed)
        XCTAssertFalse(try f.store.claim(f.id, now: f.now.addingTimeInterval(122)))
    }

    func testExpiredEventsAndEventsBeforeEnableAreSkipped() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        XCTAssertFalse(try f.store.claim(f.id, now: f.now.addingTimeInterval(301)))
        XCTAssertEqual(try f.store.record(f.id)?.phase, .skipped)
        let g = try Fixture(); try g.enable(); try g.enqueue()
        var s = try g.store.settings(); s.enabledAt = g.now.addingTimeInterval(1); try g.store.saveSettings(s)
        XCTAssertFalse(try g.store.claim(g.id, now: g.now))
    }

    func testSubscriptionEnvironmentRemovesAPIKeys() {
        let env = HandoffEnvironment.subscription(["OPENAI_API_KEY": "secret", "CODEX_API_KEY": "secret", "OPENAI_BASE_URL": "https://other",
                                                    "CODEX_ACCESS_TOKEN": "secret", "PATH": "path", "HOME": "/home"])
        XCTAssertEqual(env, ["PATH": "path", "HOME": "/home"])
    }

    func testResumeUsesExactIDAndSafeShellQuoting() throws {
        let f = try Fixture()
        var record = HandoffRecord(sessionID: f.id, transcriptPath: f.transcript.path, cwd: f.cwd.path, now: f.now)
        record.threadID = UUID().uuidString.lowercased(); record.contextReady = true
        let args = try HandoffCommands.resumeArguments(record, initial: false)
        XCTAssertEqual(args.last, record.threadID)
        XCTAssertTrue(args.contains(f.cwd.path))
        XCTAssertFalse(args.contains("--last"))
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        let script = try HandoffCommands.terminalScript(helper: URL(fileURLWithPath: "/path with 'quote'/helper"), root: f.root, recordID: f.id)
        XCTAssertTrue(String(decoding: script, as: UTF8.self).contains("'\\''"))
    }
}
