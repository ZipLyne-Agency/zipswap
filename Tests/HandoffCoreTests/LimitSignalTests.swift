import Foundation
import XCTest
@testable import HandoffCore

final class LimitSignalTests: XCTestCase {
    private let defaultProfile: [String: String] = ["HOME": "/Users/example"]

    func testOffByDefaultRecordsNothing() throws {
        let f = try Fixture()
        XCTAssertFalse(ClaudeLimitSignals.record(try f.event(), store: f.store, environment: defaultProfile))
        XCTAssertNil(ClaudeLimitSignals.latest(f.store))
    }

    func testUsageLimitStopFromTheDefaultProfileIsRecordedWithOnlyItsTime() throws {
        let f = try Fixture()
        try ClaudeLimitSignals.setEnabled(true, store: f.store)
        XCTAssertTrue(ClaudeLimitSignals.record(try f.event(), store: f.store, environment: defaultProfile, now: f.now))
        XCTAssertEqual(ClaudeLimitSignals.latest(f.store)?.at.timeIntervalSince1970 ?? 0, f.now.timeIntervalSince1970, accuracy: 0.001)
        let saved = try Data(contentsOf: f.store.root.appendingPathComponent("claude-limit-signal.json"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any]).keys
        XCTAssertEqual(Array(keys), ["at"], "no session, path or account data is kept")
        XCTAssertFalse(try f.store.settings().enabled, "handoff stays off")
        XCTAssertTrue(try f.store.records().isEmpty, "no handoff is queued")
    }

    func testOtherEventsErrorsSubagentsAndPinnedProfilesAreIgnored() throws {
        let f = try Fixture()
        try ClaudeLimitSignals.setEnabled(true, store: f.store)
        for error in ["overloaded", "server_error", "authentication_failed", "billing_error"] {
            XCTAssertFalse(ClaudeLimitSignals.record(try f.event(error: error), store: f.store, environment: defaultProfile))
        }
        XCTAssertFalse(ClaudeLimitSignals.record(try f.event("PostToolUse"), store: f.store, environment: defaultProfile))
        XCTAssertFalse(ClaudeLimitSignals.record(try f.event(agentID: "worker"), store: f.store, environment: defaultProfile))
        XCTAssertFalse(ClaudeLimitSignals.record(try f.event(), store: f.store,
                                                 environment: ["CLAUDE_CONFIG_DIR": "/Users/example/.claude-swap-backup/sessions/2"]))
        XCTAssertFalse(ClaudeLimitSignals.record(try f.event(), store: f.store,
                                                 environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/orca"]))
        XCTAssertFalse(ClaudeLimitSignals.record(Data("not json".utf8), store: f.store, environment: defaultProfile))
        XCTAssertNil(ClaudeLimitSignals.latest(f.store))
    }

    func testEmptyProfileVariablesStillMeanTheDefaultLogin() {
        XCTAssertTrue(ClaudeLimitSignals.isDefaultProfile(["CLAUDE_CONFIG_DIR": "", "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""]))
    }
}
