import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// New receipts use UTC instants; legacy helper timestamps are imported once.
/// The array account index and credential paths remain readable on app rollback.
enum SwitchJournal {
    private static let lock = NSLock()
    private static let file = Shell.home.appendingPathComponent("Library/Application Support/ZipSwap/history-v1.json")
    private struct Entry: Codable {
        let provider: Provider
        let from: String
        let to: String
        let at: Date
        let reason: String
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value
    }
    private static func read() throws -> [Entry]? {
        guard let data = try PrivateFile.readIfPresent(file) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Envelope.self, from: data)
        guard value.version == 1, value.entries.count <= 200 else { throw ShellError.failed("Unsupported switch history format.") }
        return value.entries
    }
    static func load(importing legacy: () -> [HistoryItem]) throws -> [HistoryItem] {
        try lock.withLock {
            let entries: [Entry]
            if let saved = try read() { entries = saved }
            else {
                entries = Array(legacy().prefix(100)).map { Entry(provider: $0.provider, from: $0.from, to: $0.to, at: $0.at, reason: $0.reason.isEmpty ? "Legacy log" : $0.reason) }
                try PrivateFile.write(try encoder().encode(Envelope(version: 1, entries: entries)), to: file)
            }
            return entries.map { HistoryItem(provider: $0.provider, from: $0.from, to: $0.to, at: $0.at, reason: $0.reason) }
        }
    }
    static func append(provider: Provider, from: String, to: String, reason: String) throws {
        try lock.withLock {
            var entries = try read() ?? []
            guard !entries.contains(where: { $0.provider == provider && $0.from == from && $0.to == to && Date().timeIntervalSince($0.at) < 5 }) else { return }
            entries.insert(Entry(provider: provider, from: ContextRedaction.clean(String(from.prefix(100))),
                                 to: ContextRedaction.clean(String(to.prefix(100))), at: Date(), reason: reason), at: 0)
            try PrivateFile.write(try encoder().encode(Envelope(version: 1, entries: Array(entries.prefix(200)))), to: file)
        }
    }
}
