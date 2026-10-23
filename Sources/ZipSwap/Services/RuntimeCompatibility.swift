import Foundation

struct RuntimeTool: Identifiable {
    var id: String { name }
    let name: String
    let version: String
    let issue: String?
}

enum RuntimeCompatibility {
    static func probe(_ tool: String, minimum: [Int]) async -> RuntimeTool {
        do {
            let result = try await Shell.run(tool, ["--version"], timeout: 8)
            guard result.status == 0, let version = version(in: result.out) else {
                return RuntimeTool(name: tool, version: "Unknown", issue: "Could not verify the \(tool) version.")
            }
            let supported = !version.lexicographicallyPrecedes(minimum)
            return RuntimeTool(name: tool, version: version.map(String.init).joined(separator: "."),
                               issue: supported ? nil : "Update \(tool) to \(minimum.map(String.init).joined(separator: ".")) or newer.")
        } catch { return RuntimeTool(name: tool, version: "Unavailable", issue: "\(tool) is unavailable. Install or repair it, then check tools again.") }
    }
    static func version(in text: String) -> [Int]? {
        guard let match = text.range(of: #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#, options: .regularExpression) else { return nil }
        return text[match].split(separator: ".").compactMap { Int($0) }
    }
    static func check() async -> [RuntimeTool] {
        async let helper = probe("claude-swap", minimum: [0,28,0])
        async let claude = probe("claude", minimum: [2,1,299])
        async let codex = probe("codex", minimum: [0,163,0])
        return await [helper, claude, codex]
    }
}
