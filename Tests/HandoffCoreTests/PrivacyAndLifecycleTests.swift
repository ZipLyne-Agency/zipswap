import Foundation
import XCTest
@testable import HandoffCore

final class PrivacyAndLifecycleTests: XCTestCase {
    func testUnapprovedWorkspaceCreatesNoProviderCallsAndCanBeReviewed() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        var settings = try f.store.settings(); settings.approvedWorkspaces = []; try f.store.saveSettings(settings)
        let backend = FakeBackend(), engine = HandoffEngine(store: f.store, projects: f.projects)
        let review = try XCTUnwrap(engine.prepare(f.id, now: f.now, workspaceStatus: { _ in "fixture" }, backend: { backend }))
        XCTAssertEqual(review.phase, .review); XCTAssertTrue(backend.calls.isEmpty)
        let excerpt = try TranscriptReader.read(path: f.transcript.path, sessionID: f.id)
        let context = HandoffContext.make(record: review, excerpt: excerpt, workspaceStatus: "fixture")
        try f.store.approveWorkspace(f.id, contextHash: HandoffPrivacy.digest(context), now: f.now)
        let result = try engine.prepare(f.id, now: f.now, workspaceStatus: { _ in "fixture" }, backend: { backend })
        XCTAssertEqual(result?.phase, .ready)
        XCTAssertEqual(result?.contextSHA256, HandoffPrivacy.digest(context))
    }
    func testChangedContextReturnsToReviewBeforeReservingAnAttempt() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        try f.store.update(f.id) { $0.reviewedContextSHA256 = String(repeating: "0", count: 64) }
        let backend = FakeBackend()
        let result = try HandoffEngine(store: f.store, projects: f.projects).prepare(f.id, now: f.now, workspaceStatus: { _ in "" }, backend: { backend })
        XCTAssertEqual(result?.phase, .review)
        XCTAssertNil(result?.attemptedAt)
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testArchivingCannotResetThePreparationBudget() throws {
        let f = try Fixture(); try f.enable()
        for _ in 0..<4 {
            let id = UUID().uuidString.lowercased()
            let input = ClaudeHookInput(sessionID: id, transcriptPath: f.transcript.path, cwd: f.cwd.path, event: "StopFailure", error: "rate_limit", agentID: nil)
            XCTAssertTrue(try f.store.enqueue(input, now: f.now))
            XCTAssertTrue(try f.store.claim(id, now: f.now))
            try f.store.update(id) { $0.phase = .failed }
            try f.store.archive(id)
        }
        XCTAssertTrue(try f.store.records().isEmpty)
        XCTAssertEqual(try f.store.archivedRecords().count, 4)
        try f.enqueue()
        XCTAssertFalse(try HandoffStore(root: f.store.root).claim(f.id, now: f.now))
    }
    func testFullStoreCanArchiveAndRestoreWithoutLosingRecords() throws {
        let f = try Fixture()
        var records = (0..<HandoffStore.maximumRecords).map { _ in HandoffRecord(sessionID: UUID().uuidString.lowercased(), transcriptPath: f.transcript.path, cwd: f.cwd.path, now: f.now) }
        for index in records.indices { records[index].phase = .failed }
        try f.store.write(records, name: "records.json")
        let id = records[0].id
        try f.store.archive(id)
        XCTAssertEqual(try f.store.records().count, HandoffStore.maximumRecords - 1)
        try f.store.restoreArchive(id)
        XCTAssertEqual(try f.store.records().count, HandoffStore.maximumRecords)
        XCTAssertTrue(try f.store.archivedRecords().isEmpty)
    }
    func testNoChangeRecoveryDoesNotRewriteTheStore() throws {
        let f = try Fixture(); try f.enable(); try f.enqueue()
        let url = f.store.root.appendingPathComponent("records.json")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        try f.store.recoverInterrupted(now: f.now.addingTimeInterval(1))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, before)
    }
    private func ready(_ f: Fixture) throws {
        try f.enable(); try f.enqueue()
        try f.store.update(f.id) { $0.phase = .ready; $0.contextReady = true; $0.threadID = UUID().uuidString.lowercased(); $0.codexAccountID = "fixture-account" }
    }
    func testLaunchFailurePreservesTheInitialPromptAndCanRetry() throws {
        let f = try Fixture(); try ready(f)
        XCTAssertThrowsError(try HandoffContinuation.run(store: f.store, id: f.id, executable: f.root.appendingPathComponent("missing"), environment: [:], verifyAccount: { "fixture-account" }))
        let record = try XCTUnwrap(f.store.record(f.id))
        XCTAssertEqual(record.phase, .ready)
        XCTAssertNil(record.startedAt)
        XCTAssertNil(record.continuationAttemptedAt)
    }
    func testChangedContinuationIdentityStartsNoConsumer() throws {
        let f = try Fixture(); try ready(f)
        XCTAssertThrowsError(try HandoffContinuation.run(store: f.store, id: f.id, executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:], verifyAccount: { "another-account" }))
        XCTAssertNil(try f.store.record(f.id)?.startedAt)
    }
    func testLegacyStartedThreadsCanReopenWithoutResendingTheInitialPrompt() throws {
        let f = try Fixture(); try ready(f)
        try f.store.update(f.id) { $0.codexAccountID = nil; $0.startedAt = f.now }
        let script = f.root.appendingPathComponent("record-arguments")
        let arguments = f.root.appendingPathComponent("arguments")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(arguments.path)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertEqual(try HandoffContinuation.run(store: f.store, id: f.id, executable: script, environment: [:], verifyAccount: { "fixture-account" }), 0)
        let text = try String(contentsOf: arguments, encoding: .utf8)
        let record = try XCTUnwrap(f.store.record(f.id))
        XCTAssertEqual(text, try HandoffCommands.resumeArguments(record, initial: false).joined(separator: "\n") + "\n")
    }
    func testLegacyUnstartedThreadsStillNeedAccountBinding() throws {
        let f = try Fixture(); try ready(f)
        try f.store.update(f.id) { $0.codexAccountID = nil }
        XCTAssertThrowsError(try HandoffContinuation.run(store: f.store, id: f.id, executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:], verifyAccount: { "fixture-account" }))
        XCTAssertNil(try f.store.record(f.id)?.continuationAttemptedAt)
    }
    func testConsumerLeaseRejectsDuplicateTerminalLaunch() throws {
        let f = try Fixture(); try ready(f)
        let lease = try HandoffConsumerLease(root: f.store.root, recordID: f.id)
        defer { withExtendedLifetime(lease) {} }
        var called = false
        XCTAssertThrowsError(try HandoffContinuation.run(store: f.store, id: f.id, executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:], verifyAccount: { called = true; return "fixture-account" }))
        XCTAssertFalse(called)
    }
    func testPIDReuseDoesNotCountAsALiveConsumer() throws {
        let f = try Fixture(); try ready(f)
        let current = try XCTUnwrap(ProcessIdentity.capture(getpid()))
        try f.store.update(f.id) { $0.phase = .running; $0.consumerPID = getpid(); $0.consumerStartTime = current.startTime - 100; $0.updatedAt = f.now.addingTimeInterval(-121) }
        try f.store.recoverInterrupted(now: f.now)
        XCTAssertEqual(try f.store.record(f.id)?.phase, .failed)
        XCTAssertNotNil(ProcessIdentity.capture(getpid()))
    }
    func testExplicitExhaustionTrustCoversPollingButNotReset() {
        let now = Date()
        let until = UsageValidity.trustUntil(fetchedAt: now.addingTimeInterval(-300), exhausted: true, reset: now.addingTimeInterval(60))
        let full = HandoffAccountUsage(active: true, disabled: false, percent: 100, blocked: true, healthy: true, fetchedAt: now.addingTimeInterval(-300), trustUntil: until)
        XCTAssertTrue(HandoffUsagePolicy.evaluate([full], rotationEnabled: true, now: now).claudeExhausted)
        XCTAssertFalse(HandoffUsagePolicy.evaluate([full], rotationEnabled: true, now: now.addingTimeInterval(61)).claudeExhausted)
    }
    func testProductionImportOmitsRawToolResultsAndRedactsQueryTokens() throws {
        let f = try Fixture()
        let data = try jsonLines([["type": "user", "uuid": "x", "message": ["content": [["type": "text", "text": "Visible request"], ["type": "tool_result", "content": "PRIVATE_RAW_OUTPUT"]]]]])
        try data.write(to: f.transcript)
        XCTAssertFalse(try TranscriptReader.read(path: f.transcript.path, sessionID: f.id).text.contains("PRIVATE_RAW_OUTPUT"))
        let clean = ContextRedaction.clean("https://example.test/path?token=syntheticquerysecret&x=y api\u{200B}_key=syntheticinvisiblesecret")
        XCTAssertFalse(clean.contains("syntheticquerysecret"))
        XCTAssertFalse(clean.contains("syntheticinvisiblesecret"))
    }
}
