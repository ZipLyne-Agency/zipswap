import Foundation

public protocol HandoffBackend {
    func preflight() throws
    func create(cwd: String) throws -> String
    func inject(threadID: String, context: String) throws
    func name(threadID: String, name: String) throws
    func verify(threadID: String) throws
    func close()
}

public final class LocalCodexBackend: HandoffBackend {
    private let rpc: CodexRPC
    public init(rpc: CodexRPC) { self.rpc = rpc }

    public func preflight() throws {
        let account = try rpc.call("account/read", params: ["refreshToken": false])
        guard let info = account["account"] as? [String: Any], info["type"] as? String == "chatgpt" else {
            throw HandoffError.unavailable("Sign in to Codex with ChatGPT before using handoff. API billing is not used.")
        }
        let limits = try rpc.call("account/rateLimits/read")
        guard let snapshot = limits["rateLimits"] as? [String: Any] else {
            throw HandoffError.unavailable("Codex subscription usage is unavailable. No thread was created.")
        }
        guard limits["ordinaryUsageAllowed"] as? Bool != false,
              !(snapshot["rateLimitReachedType"] is String) else {
            throw HandoffError.unavailable("Codex has reached its usage limit too. No credits or resets were purchased.")
        }
        var foundWindow = false
        for key in ["primary", "secondary"] {
            if let window = snapshot[key] as? [String: Any], let used = window["usedPercent"] as? Double {
                foundWindow = true
                guard used.isFinite, used >= 0, used < 100 else {
                    throw HandoffError.unavailable("Codex has no confirmed subscription allowance remaining.")
                }
            }
        }
        guard foundWindow else { throw HandoffError.unavailable("Codex did not report a subscription allowance.") }
    }

    public func create(cwd: String) throws -> String {
        let result = try rpc.call("thread/start", params: [
            "cwd": cwd, "modelProvider": "openai", "ephemeral": false,
            "approvalPolicy": "on-request", "sandbox": "workspace-write",
            "serviceName": "zipswap_handoff",
        ])
        guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String,
              HandoffPaths.validID(id) else { throw HandoffError.invalid("Codex did not return a valid thread ID.") }
        return id
    }

    public func inject(threadID: String, context: String) throws {
        _ = try rpc.call("thread/inject_items", params: ["threadId": threadID, "items": [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": context]]],
        ]])
    }

    public func name(threadID: String, name: String) throws {
        _ = try rpc.call("thread/name/set", params: ["threadId": threadID, "name": name])
    }

    public func verify(threadID: String) throws {
        let result = try rpc.call("thread/read", params: ["threadId": threadID])
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == threadID,
              thread["ephemeral"] as? Bool == false else {
            throw HandoffError.invalid("Codex did not confirm the saved thread.")
        }
    }

    public func close() { rpc.close() }
}

public struct HandoffEngine {
    public let store: HandoffStore
    public let projects: URL
    public init(store: HandoffStore, projects: URL = HandoffPaths.claudeProjects) {
        self.store = store
        self.projects = projects
    }

    /// Exactly one caller claims a source session. A crash/failure is terminal;
    /// partial thread ids remain visible, but are never opened without context.
    @discardableResult
    public func prepare(_ id: String, now: Date = Date(), workspaceStatus: (String) -> String,
                        backend: () throws -> HandoffBackend) throws -> HandoffRecord? {
        guard let record = try store.record(id), record.phase == .queued else { return try store.record(id) }
        if let reason = HandoffAdmission.reasonToSkip(record: record, settings: try store.settings(),
                                                     usage: try store.usage(), now: now) {
            try store.update(id) {
                $0.phase = .skipped; $0.detail = reason; $0.updatedAt = now
                $0.admissionChecks = ($0.admissionChecks ?? 0) + 1
            }
            return try store.record(id)
        }
        guard try store.claim(id, now: now) else { return try store.record(id) }
        do {
            let input = ClaudeHookInput(sessionID: record.sourceSessionID, transcriptPath: record.transcriptPath,
                                       cwd: record.cwd, event: "StopFailure", error: "rate_limit", agentID: nil)
            try HandoffPaths.validate(input, projects: projects)
            let excerpt = try TranscriptReader.read(path: record.transcriptPath, sessionID: record.sourceSessionID)
            let context = HandoffContext.make(record: record, excerpt: excerpt, workspaceStatus: workspaceStatus(record.cwd))
            try requireEnabled()
            let client = try backend()
            defer { client.close() }
            try client.preflight()
            try requireEnabled()
            let threadID = try client.create(cwd: record.cwd)
            try store.update(id) { $0.threadID = threadID; $0.updatedAt = Date() }
            try requireEnabled()
            try client.inject(threadID: threadID, context: context)
            try client.name(threadID: threadID, name: "Claude handoff · \(record.title) · \(id.prefix(8))")
            try client.verify(threadID: threadID)
            try store.update(id) {
                $0.contextReady = true
                $0.phase = .ready
                $0.detail = "\(excerpt.includedMessages) messages imported. Open the thread to continue in Codex."
                $0.updatedAt = Date()
            }
        } catch {
            try store.update(id) {
                $0.phase = .failed
                $0.detail = ContextRedaction.clean(String(error.localizedDescription.prefix(350)))
                $0.updatedAt = Date()
            }
        }
        return try store.record(id)
    }

    private func requireEnabled() throws {
        guard try store.settings().enabled else {
            throw HandoffError.unavailable("Handoff was turned off during preparation. No Codex turn was started.")
        }
    }
}
