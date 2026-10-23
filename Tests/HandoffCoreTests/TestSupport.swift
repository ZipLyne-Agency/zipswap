import Foundation
import XCTest
@testable import HandoffCore

final class Fixture {
    let root: URL
    let projects: URL
    let cwd: URL
    let store: HandoffStore
    let id = UUID().uuidString.lowercased()
    let now = Date()
    var transcript: URL { projects.appendingPathComponent("project/\(id).jsonl") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-tests-\(UUID())")
        projects = root.appendingPathComponent("claude/projects")
        cwd = root.appendingPathComponent("project with 'quotes' and $(literal)")
        store = HandoffStore(root: root.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try writeTranscript()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func enable() throws {
        var settings = HandoffSettings()
        settings.enabled = true
        settings.enabledAt = now.addingTimeInterval(-1)
        settings.approvedWorkspaces = [HandoffPrivacy.canonicalWorkspace(cwd.path)]
        try store.saveSettings(settings)
        try store.saveUsage(HandoffUsage(checkedAt: now, activePercent: 100, claudeExhausted: true, explanation: "No Claude allowance remains."))
    }

    func event(_ name: String = "StopFailure", error: String = "rate_limit", agentID: String? = nil) throws -> Data {
        var data: [String: Any] = ["session_id": id, "transcript_path": transcript.path, "cwd": cwd.path,
                                   "hook_event_name": name, "error": error]
        if let agentID { data["agent_id"] = agentID }
        return try JSONSerialization.data(withJSONObject: data)
    }

    func enqueue() throws {
        _ = try ClaudeHandoffHook.handle(event(), store: store, projects: projects, now: now)
    }

    func writeTranscript() throws {
        let rows: [[String: Any]] = [
            ["type": "user", "uuid": "one", "parentUuid": NSNull(), "sessionId": id,
             "message": ["role": "user", "content": "Fix the green widget. Keep the handoff marker ORCHID-742. Do not deploy."]],
            ["type": "assistant", "uuid": "two", "parentUuid": "one", "sessionId": id,
             "message": ["role": "assistant", "content": [["type": "text", "text": "Updated Widget.swift; tests still need to run."]]]],
        ]
        try jsonLines(rows).write(to: transcript)
    }
}

func jsonLines(_ rows: [[String: Any]]) throws -> Data {
    var data = Data()
    for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
    return data
}

final class FakeBackend: HandoffBackend {
    let threadID = UUID().uuidString.lowercased()
    var calls: [String] = []
    var context = ""
    var failAt: String?
    var onPreflight: (() throws -> Void)?
    func step(_ name: String) throws {
        calls.append(name)
        if failAt == name { throw HandoffError.unavailable("Synthetic \(name) failure") }
    }
    func preflight() throws { try step("preflight"); try onPreflight?() }
    func create(cwd: String) throws -> String { try step("create"); return threadID }
    func inject(threadID: String, context: String) throws { try step("inject"); self.context = context }
    func name(threadID: String, name: String) throws { try step("name") }
    func verify(threadID: String) throws { try step("verify") }
    func close() { calls.append("close") }
}
