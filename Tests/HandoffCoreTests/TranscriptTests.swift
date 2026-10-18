import Foundation
import XCTest
@testable import HandoffCore

final class TranscriptTests: XCTestCase {
    func row(_ id: String, parent: String?, text: String, role: String = "user") -> [String: Any] {
        ["type": role, "uuid": id, "parentUuid": parent as Any? ?? NSNull(),
         "message": ["role": role, "content": text]]
    }

    func testActiveBranchAndPartialFinalLine() throws {
        var data = try jsonLines([
            row("a", parent: nil, text: "original goal"),
            row("b", parent: "a", text: "abandoned direction", role: "assistant"),
            row("c", parent: "a", text: "corrected direction"),
            row("d", parent: "c", text: "current progress", role: "assistant"),
        ])
        data.append(Data("{partial".utf8))
        let result = try TranscriptReader.parse(data, sessionID: "test")
        XCTAssertTrue(result.text.contains("original goal"))
        XCTAssertTrue(result.text.contains("corrected direction"))
        XCTAssertFalse(result.text.contains("abandoned direction"))
        XCTAssertTrue(result.omittedContent)
        XCTAssertEqual(result.includedMessages, 3)
    }

    func testCompactionSummaryIsPreserved() throws {
        let data = try jsonLines([
            row("a", parent: nil, text: "outdated material"),
            ["type": "system", "subtype": "compact_boundary", "uuid": "b", "parentUuid": "a"],
            row("c", parent: "b", text: "Summary: fix widget; do not deploy"),
            row("d", parent: "c", text: "remaining task"),
        ])
        let result = try TranscriptReader.parse(data, sessionID: "test")
        XCTAssertTrue(result.text.contains("Summary:"))
        XCTAssertFalse(result.text.contains("outdated material"))
    }

    func testThinkingOmittedToolArgumentsNotReplayedAndSecretsRedacted() throws {
        let data = try jsonLines([
            row("a", parent: nil, text: "task"),
            ["type": "assistant", "uuid": "b", "parentUuid": "a", "message": ["content": [
                ["type": "thinking", "thinking": "hidden chain"],
                ["type": "tool_use", "id": "tool1", "name": "Bash", "input": ["command": "dangerous_command_with_secret"]],
                ["type": "text", "text": "visible response"],
            ]]],
            ["type": "user", "uuid": "c", "parentUuid": "b", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "tool1", "content": "OPENAI_API_KEY=sk-proj-abcdefghijklmnop\n3 checks passed"],
                ["type": "image", "source": ["data": "image-secret"]],
            ]]],
        ])
        let result = try TranscriptReader.parse(data, sessionID: "test")
        XCTAssertFalse(result.text.contains("hidden chain"))
        XCTAssertFalse(result.text.contains("dangerous_command"))
        XCTAssertFalse(result.text.contains("abcdefghijklmnop"))
        XCTAssertFalse(result.text.contains("image-secret"))
        XCTAssertTrue(result.text.contains("3 checks passed"))
        XCTAssertTrue(result.text.contains("Tool requested: Bash"))
    }

    func testLongHistoryIsBoundedAndLatestRequestSurvives() throws {
        var rows: [[String: Any]] = []
        for i in 0..<100 {
            rows.append(row(String(i), parent: i == 0 ? nil : String(i - 1), text: String(repeating: "z", count: 10000) + " last-\(i)"))
        }
        let result = try TranscriptReader.parse(jsonLines(rows), sessionID: "test")
        XCTAssertLessThanOrEqual(result.text.count, TranscriptReader.maximumContextCharacters + 100)
        XCTAssertTrue(result.text.contains("last-99"))
        XCTAssertTrue(result.omittedContent)
    }

    func testSubagentAndDifferentSessionCannotBecomeLeaf() throws {
        var other = row("b", parent: "a", text: "wrong agent"); other["isSidechain"] = true
        var wrong = row("c", parent: "a", text: "wrong session"); wrong["sessionId"] = "other"
        let result = try TranscriptReader.parse(jsonLines([row("a", parent: nil, text: "right"), other, wrong]), sessionID: "test")
        XCTAssertTrue(result.text.contains("right"))
        XCTAssertFalse(result.text.contains("wrong"))
    }

    func testEmptyTranscriptFailsInsteadOfLaunchingWithoutContext() throws {
        XCTAssertThrowsError(try TranscriptReader.parse(Data(), sessionID: "test"))
    }
}
