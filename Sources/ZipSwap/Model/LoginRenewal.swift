import Foundation

/// Lets an agent renew a saved Claude login: `open -g "zipswap://renew-login?email=…"`
/// runs the same Renew Sign-In as the menu, but instead of opening a browser the
/// sign-in link goes into a private status file the agent reads and finishes in
/// its own browser. Only a saved account's email is accepted; nothing else in the
/// request is used.
enum LoginRenewal {
    static let scheme = "zipswap"
    static let host = "renew-login"
    /// Set on `claude auth login` so ZipSwapBridge, run as its BROWSER, writes the link here.
    static let linkFileVariable = "ZIPSWAP_SIGN_IN_URL_FILE"

    static var directory: URL {
        Shell.home.appendingPathComponent("Library/Application Support/ZipSwap/ClaudeLogins")
    }
    static var statusFile: URL { directory.appendingPathComponent("renew-status.json") }
    static var linkFile: URL { directory.appendingPathComponent("renew-sign-in-url") }

    /// The email in a `zipswap://renew-login?email=` URL, or nil for any other URL.
    static func email(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let email = items.first(where: { $0.name == "email" })?.value?.trimmingCharacters(in: .whitespaces),
              email.contains("@"), email.count <= 254 else { return nil }
        return email
    }

    /// Whether the request asks to stop the renewal instead (`&cancel=1`).
    static func isCancel(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cancel" && $0.value == "1" } == true
    }

    /// A sign-in link worth handing over: Claude's own authorize page on https.
    static func isSignInLink(_ text: String) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let claude = ["claude.ai", "claude.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        return claude && url.path.contains("/oauth/authorize")
    }

    enum State: String, Codable {
        /// The request was accepted and sign-in is starting.
        case starting
        /// `signInURL` is ready: open it in a browser signed in as `email`.
        case openLink = "open-link"
        case done, failed
    }

    struct Status: Codable, Equatable {
        let email: String
        let state: State
        var message: String?
        var signInURL: String?
        /// The new sign-in end after a renewal, ISO 8601.
        var signInEnds: String?
        let updatedAt: String
    }

    static func write(_ status: Status, to file: URL = statusFile) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(status).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func status(_ email: String, _ state: State, message: String? = nil, signInURL: String? = nil,
                       signInEnds: Date? = nil, now: Date = .now) -> Status {
        let iso = ISO8601DateFormatter()
        return Status(email: email, state: state, message: message, signInURL: signInURL,
                      signInEnds: signInEnds.map { iso.string(from: $0) }, updatedAt: iso.string(from: now))
    }

    /// Waits for the bridge to write the sign-in link, up to `timeout`.
    static func awaitLink(in file: URL = linkFile, timeout: TimeInterval = 60) async throws -> String {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            try Task.checkCancellation()
            if let text = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               isSignInLink(text) { return text }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw ShellError.failed("Claude Code did not hand over a sign-in link.")
    }
}
