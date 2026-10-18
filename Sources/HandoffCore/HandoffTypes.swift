import Foundation

public enum HandoffError: LocalizedError {
    case invalid(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .unavailable(let message): return message
        }
    }
}

public struct HandoffSettings: Codable, Equatable {
    public var enabled = false
    public var enabledAt: Date?
    public var automaticallyOpen = true
    public var warningPercent = 90.0
    public init() {}
}

public struct HandoffUsage: Codable {
    public var checkedAt: Date
    public var activePercent: Double?
    public var claudeExhausted: Bool
    public var explanation: String

    public init(checkedAt: Date, activePercent: Double?, claudeExhausted: Bool, explanation: String) {
        self.checkedAt = checkedAt
        self.activePercent = activePercent
        self.claudeExhausted = claudeExhausted
        self.explanation = explanation
    }

    public func isFresh(at now: Date) -> Bool {
        (0...180).contains(now.timeIntervalSince(checkedAt))
    }
}

public enum HandoffPhase: String, Codable {
    case queued, preparing, ready, opened, failed, skipped, cancelled
}

public struct HandoffRecord: Codable, Identifiable, Equatable {
    public var id: String { sourceSessionID }
    public let sourceSessionID: String
    public let transcriptPath: String
    public let cwd: String
    public let createdAt: Date
    public var updatedAt: Date
    public var phase: HandoffPhase = .queued
    public var threadID: String?
    public var contextReady = false
    public var autoOpenAttempted = false
    public var startedAt: Date?
    public var attemptedAt: Date?
    public var lastEventAt: Date?
    public var admissionChecks: Int?
    public var detail = "Waiting for ZipSwap to prepare the Codex thread."

    public init(sessionID: String, transcriptPath: String, cwd: String, now: Date) {
        sourceSessionID = sessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        createdAt = now
        updatedAt = now
    }

    public var title: String { URL(fileURLWithPath: cwd).lastPathComponent }
    public var canOpen: Bool { contextReady && threadID != nil }
    public var eventDate: Date { lastEventAt ?? createdAt }
}

public struct ClaudeHookInput: Decodable {
    public let sessionID: String
    public let transcriptPath: String
    public let cwd: String
    public let event: String
    public let error: String?
    public let agentID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", transcriptPath = "transcript_path", cwd
        case event = "hook_event_name", error, agentID = "agent_id"
    }
}

public enum HandoffPaths {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ZipSwap/Handoff", isDirectory: true)
    }
    public static var claudeProjects: URL {
        let configured = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        let base = configured.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    public static func validID(_ value: String) -> Bool { UUID(uuidString: value) != nil }

    public static func validate(_ input: ClaudeHookInput, projects: URL) throws {
        guard validID(input.sessionID), input.agentID == nil else {
            throw HandoffError.invalid("Only a root Claude Code session can be handed off.")
        }
        guard input.cwd.hasPrefix("/"), input.transcriptPath.hasPrefix("/") else {
            throw HandoffError.invalid("Claude supplied a relative project or transcript path.")
        }
        let transcript = URL(fileURLWithPath: input.transcriptPath).resolvingSymlinksInPath()
        let allowed = projects.resolvingSymlinksInPath().path + "/"
        guard transcript.path.hasPrefix(allowed),
              transcript.lastPathComponent.lowercased() == input.sessionID.lowercased() + ".jsonl",
              (try? transcript.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw HandoffError.invalid("The source transcript is missing or outside Claude's project history.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HandoffError.invalid("The source project folder no longer exists.")
        }
    }
}
