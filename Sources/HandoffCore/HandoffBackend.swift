import Foundation

public protocol HandoffBackend {
    var accountID: String? { get }
    func preflight() throws
    func create(cwd: String) throws -> String
    func inject(threadID: String, context: String) throws
    func name(threadID: String, name: String) throws
    func verify(threadID: String) throws
    func close()
}

public extension HandoffBackend { var accountID: String? { nil } }

public final class LocalCodexBackend: HandoffBackend {
    private let rpc: CodexRPC
    public private(set) var accountID: String?
    public init(rpc: CodexRPC) { self.rpc = rpc }

    public func preflight() throws {
        let account = try rpc.call("account/read", params: ["refreshToken": false])
        guard let info = account["account"] as? [String: Any], info["type"] as? String == "chatgpt" else {
            throw HandoffError.unavailable("Sign in to Codex with ChatGPT before using handoff. API billing is not used.")
        }
        let limits = try rpc.call("account/rateLimits/read")
        guard let identity = limits["accountId"] as? String, !identity.isEmpty else {
            throw HandoffError.unavailable("Codex did not verify the subscription account. No thread was created.")
        }
        let snapshot = try CodexUsageSnapshot(limits, expectedAccountID: identity)
        guard snapshot.ordinaryUsageAllowed, !snapshot.reached else {
            throw HandoffError.unavailable("Codex has reached its usage limit too. No credits or resets were purchased.")
        }
        accountID = identity
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
        guard HandoffPrivacy.allowed(record.cwd, settings: try store.settings()) else {
            try store.update(id) { $0.phase = .review; $0.detail = "Review the context and allow this workspace before transferring it to Codex."; $0.updatedAt = now }
            return try store.record(id)
        }
        let excerpt: TranscriptExcerpt
        let context: String
        let digest: String
        do {
            let input = ClaudeHookInput(sessionID: record.sourceSessionID, transcriptPath: record.transcriptPath,
                                       cwd: record.cwd, event: "StopFailure", error: "rate_limit", agentID: nil)
            try HandoffPaths.validate(input, projects: projects)
            excerpt = try TranscriptReader.read(path: record.transcriptPath, sessionID: record.sourceSessionID)
            context = HandoffContext.make(record: record, excerpt: excerpt, workspaceStatus: workspaceStatus(record.cwd))
            digest = HandoffPrivacy.digest(context)
        } catch {
            try store.update(id) { $0.phase = .failed; $0.detail = ContextRedaction.clean(error.localizedDescription); $0.updatedAt = now }
            return try store.record(id)
        }
        if let reviewed = record.reviewedContextSHA256, reviewed != digest {
            try store.update(id) { $0.phase = .review; $0.reviewedContextSHA256 = nil; $0.detail = "The context changed. Review it again before transfer."; $0.updatedAt = now }
            return try store.record(id)
        }
        guard try store.claim(id, now: now) else { return try store.record(id) }
        do {
            try requireEnabled(cwd: record.cwd)
            let client = try backend()
            defer { client.close() }
            try client.preflight()
            try store.update(id) { $0.codexAccountID = client.accountID; $0.contextSHA256 = digest }
            try requireEnabled(cwd: record.cwd)
            let threadID = try client.create(cwd: record.cwd)
            try store.update(id) { $0.threadID = threadID; $0.updatedAt = Date() }
            try requireEnabled(cwd: record.cwd)
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

    private func requireEnabled(cwd: String) throws {
        let settings = try store.settings()
        guard settings.enabled, HandoffPrivacy.allowed(cwd, settings: settings) else {
            throw HandoffError.unavailable("Handoff was turned off during preparation. No Codex turn was started.")
        }
    }
}
