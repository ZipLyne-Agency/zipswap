import Foundation
import Testing
@testable import ZipSwapCore

struct LoginRenewalTests {
    @Test func readsTheEmailFromARenewRequest() {
        #expect(LoginRenewal.email(from: URL(string: "zipswap://renew-login?email=admin@ziplyne.agency")!) == "admin@ziplyne.agency")
        #expect(LoginRenewal.email(from: URL(string: "ZipSwap://Renew-Login?email=dev%40ziplyne.agency")!) == "dev@ziplyne.agency")
    }

    @Test func ignoresOtherRequests() {
        #expect(LoginRenewal.email(from: URL(string: "zipswap://switch?email=admin@ziplyne.agency")!) == nil)
        #expect(LoginRenewal.email(from: URL(string: "https://renew-login?email=admin@ziplyne.agency")!) == nil)
        #expect(LoginRenewal.email(from: URL(string: "zipswap://renew-login?email=nobody")!) == nil)
        #expect(LoginRenewal.email(from: URL(string: "zipswap://renew-login")!) == nil)
    }

    @Test func acceptsOnlyClaudeAuthorizeLinks() {
        #expect(LoginRenewal.isSignInLink("https://claude.com/cai/oauth/authorize?code=true&redirect_uri=http%3A%2F%2Flocalhost%3A1%2Fcallback"))
        #expect(LoginRenewal.isSignInLink("https://claude.ai/oauth/authorize?code=true"))
        #expect(!LoginRenewal.isSignInLink("http://claude.ai/oauth/authorize"))
        #expect(!LoginRenewal.isSignInLink("https://claude.ai.evil.example/oauth/authorize"))
        #expect(!LoginRenewal.isSignInLink("https://evilclaude.ai/oauth/authorize"))
        #expect(!LoginRenewal.isSignInLink("https://claude.ai/settings"))
    }

    @Test func writesAPrivateStatusFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("renewal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("renew-status.json")
        let ends = Date(timeIntervalSince1970: 1_800_000_000)
        try LoginRenewal.write(LoginRenewal.status("admin@ziplyne.agency", .done, signInEnds: ends), to: file)
        let status = try JSONDecoder().decode(LoginRenewal.Status.self, from: Data(contentsOf: file))
        #expect(status.state == .done)
        #expect(status.email == "admin@ziplyne.agency")
        #expect(status.signInEnds == ISO8601DateFormatter().string(from: ends))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(raw.contains("\"open-link\"") == false && raw.contains("\"done\""))
    }

    @Test func waitsForTheLinkTheBridgeWrites() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("renewal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("renew-sign-in-url")
        let link = "https://claude.com/cai/oauth/authorize?code=true"
        Task {
            try await Task.sleep(for: .milliseconds(400))
            try Data("not a link\n".utf8).write(to: file)
            try await Task.sleep(for: .milliseconds(400))
            try Data((link + "\n").utf8).write(to: file)
        }
        #expect(try await LoginRenewal.awaitLink(in: file, timeout: 5) == link)
    }
}

struct LoginRenewalCancelTests {
    @Test func readsACancelRequest() {
        let url = URL(string: "zipswap://renew-login?cancel=1&email=go@ziplyne.agency")!
        #expect(LoginRenewal.isCancel(url))
        #expect(LoginRenewal.email(from: url) == "go@ziplyne.agency")
        #expect(!LoginRenewal.isCancel(URL(string: "zipswap://renew-login?email=go@ziplyne.agency")!))
    }
}
