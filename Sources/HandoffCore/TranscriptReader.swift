import Foundation

public struct TranscriptExcerpt {
    public let text: String
    public let includedMessages: Int
    public let omittedContent: Bool
}

/// Imports visible messages as quoted history, never as native tool invocations.
/// Follows the active parent chain so abandoned branches are not replayed.
public enum TranscriptReader {
    public static let maximumReadBytes = 12 * 1024 * 1024
    public static let maximumContextCharacters = 96_000

    public static func read(path: String, sessionID: String, includeToolResults: Bool = false) throws -> TranscriptExcerpt {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > maximumReadBytes ? size - UInt64(maximumReadBytes) : 0
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: maximumReadBytes) ?? Data()
        if offset > 0, let newline = data.firstIndex(of: 10) { data.removeSubrange(...newline) }
        return try parse(data, sessionID: sessionID, truncatedFile: offset > 0, includeToolResults: includeToolResults)
    }

    public static func parse(_ data: Data, sessionID: String, truncatedFile: Bool = false, includeToolResults: Bool = true) throws -> TranscriptExcerpt {
        guard data.count <= maximumReadBytes else { throw HandoffError.invalid("Transcript input exceeds its size limit.") }
        var records: [Entry] = []
        var omitted = truncatedFile
        var positions: [String: Int] = [:]
        for line in data.split(separator: 10) {
            guard line.count <= 1_048_576 else { omitted = true; continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                omitted = true; continue // A concurrent append may leave one partial final line.
            }
            guard object["isSidechain"] as? Bool != true else { continue }
            if let sid = object["sessionId"] as? String, sid.lowercased() != sessionID.lowercased() { continue }
            guard let id = object["uuid"] as? String else { continue }
            let type = object["type"] as? String ?? ""
            let parent = object["parentUuid"] as? String
            let message = object["message"] as? [String: Any]
            let isError = object["isApiErrorMessage"] as? Bool == true
            let compact = object["subtype"] as? String == "compact_boundary"
            var text = ""
            if ["user", "assistant"].contains(type), !isError {
                text = visibleText(message?["content"], omitted: &omitted, includeToolResults: includeToolResults)
            } else if type == "summary" {
                text = object["summary"] as? String ?? ""
            }
            let entry = Entry(id: id, parent: parent, role: type, text: text, compact: compact)
            if let index = positions[id] { records[index] = entry }
            else { positions[id] = records.count; records.append(entry) }
        }
        guard let leaf = records.last(where: { !$0.text.isEmpty }) else {
            throw HandoffError.invalid("The Claude transcript contains no transferable conversation.")
        }
        var chain: [Entry] = []
        var visited = Set<String>()
        var current: Entry? = leaf
        while let entry = current, visited.insert(entry.id).inserted {
            if !entry.text.isEmpty { chain.append(entry) }
            if entry.compact { omitted = true; break }
            guard let parent = entry.parent else { break }
            guard let index = positions[parent] else { omitted = true; break }
            current = records[index]
        }
        // Keep the most recent material within the limit; summaries after a
        // compaction boundary are ordinary user messages and stay in the chain.
        var budget = maximumContextCharacters
        var selected: [String] = []
        for entry in chain {
            let clean = ContextRedaction.clean(entry.text)
            let cap = entry.role == "user" ? 16_000 : 10_000
            let clipped = clip(clean, maximum: min(cap, budget))
            if clipped != clean { omitted = true }
            guard !clipped.isEmpty, budget > 100 else { omitted = true; break }
            let formatted = "[\(entry.role.uppercased())]\n\(clipped)"
            selected.append(formatted)
            budget -= formatted.count + 2
        }
        guard !selected.isEmpty else { throw HandoffError.invalid("The Claude transcript has no usable context.") }
        return TranscriptExcerpt(text: selected.reversed().joined(separator: "\n\n"),
                                 includedMessages: selected.count, omittedContent: omitted)
    }

    private struct Entry {
        let id: String
        let parent: String?
        let role: String
        let text: String
        let compact: Bool
    }

    private static func visibleText(_ content: Any?, omitted: inout Bool, includeToolResults: Bool) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text": return block["text"] as? String
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                // Commands and arbitrary tool arguments may embed credentials.
                // Preserve file targets and a correlation id, not executable input.
                let paths = ["file_path", "path", "workdir"].compactMap { input[$0] as? String }
                return "[Tool requested: \(name); id: \(block["id"] as? String ?? "unknown"); paths: \(paths.joined(separator: ", ")). Verify its result before repeating.]"
            case "tool_result":
                guard includeToolResults else {
                    omitted = true
                    return "[Tool result omitted. Inspect current files before repeating work.]"
                }
                let result = visibleText(block["content"], omitted: &omitted, includeToolResults: includeToolResults)
                if result.count > 3000 { omitted = true }
                return "[Tool result \(block["tool_use_id"] as? String ?? "unknown"), error=\(block["is_error"] as? Bool ?? false)]\n\(clip(result, maximum: 3000))"
            case "thinking", "redacted_thinking": return nil
            case "image", "document":
                omitted = true
                return "[Attachment omitted. Refer to the original Claude session if required.]"
            default:
                omitted = true
                return nil
            }
        }.joined(separator: "\n")
    }

    static func clip(_ text: String, maximum: Int) -> String {
        guard maximum > 80 else { return "" }
        guard text.count > maximum else { return text }
        let half = (maximum - 40) / 2
        return String(text.prefix(half)) + "\n[...excerpt truncated...]\n" + String(text.suffix(half))
    }
}

public enum ContextRedaction {
    public static func clean(_ text: String) -> String {
        var result = text.unicodeScalars.filter {
            let value = $0.value
            return (!CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t")
                && !(0x200B...0x200F).contains(value) && !(0x202A...0x202E).contains(value)
                && !(0x2060...0x206F).contains(value) && value != 0xFEFF
        }.map(String.init).joined()
        let patterns = [
            #"(?i)\b(?:sk-(?:proj-|ant-)?|gh[pousr]_|github_pat_|xox[baprs]-)[A-Za-z0-9_\-]{12,}"#,
            #"(?i)(?:Bearer\s+)[A-Za-z0-9._~+/\-=]{8,}"#,
            #"(?i)\b(?:[A-Z0-9_]{0,96}(?:API_KEY|ACCESS_TOKEN|REFRESH_TOKEN|PASSWORD|SECRET|AUTHORIZATION|COOKIE)[A-Z0-9_]{0,96}[\"']?\s*[:=]\s*)[^\r\n,}]+"#,
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"(?i)\b(?:postgres(?:ql)?|mysql|redis)://[^\s\"'<>]+"#,
            #"(?i)[?&](?:token|key|secret|password|code|auth|signature|sig|access_token|refresh_token|api_key)=[^\s&#\"'<>]+"#,
            #"(?i)\b(?:token|secret|password|api[_-]?key|access[_-]?token|refresh[_-]?token)[\"']?\s*[:=]\s*[\"']?[^\s,}\"']+"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                          withTemplate: "[REDACTED]")
        }
        return result
    }
}
