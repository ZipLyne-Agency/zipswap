import Foundation
#if SWIFT_PACKAGE
import HandoffCore
#endif

/// Discovers local Antigravity / Gemini OAuth logins and reads their Cloud Code
/// usage windows. Credentials are read-only: ZipSwap never modifies T3 Code's
/// or Antigravity CLI's token files.
///
/// Endpoint selection and quota-summary mapping follow OpenUsage (MIT, Robin Ebers;
/// see THIRD_PARTY_NOTICES.md).
enum GeminiService {
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    private static let oauthConfigFile = Shell.home.appendingPathComponent("Library/Application Support/ZipSwap/gemini-oauth.json")

    private struct OAuthClientConfig: Decodable {
        let clientID: String
        let clientSecret: String
    }

    private static func loadOAuthClientConfig() -> OAuthClientConfig? {
        guard let data = try? PrivateFile.readIfPresent(oauthConfigFile),
              let config = try? JSONDecoder().decode(OAuthClientConfig.self, from: data),
              !config.clientID.isEmpty, !config.clientSecret.isEmpty else { return nil }
        return config
    }

    /// Plan and project lookups prefer production.
    static let cloudCodeURLs = [
        "https://cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.googleapis.com",
    ]
    /// Production can return untouched Gemini windows; daily has the active counters.
    /// Fall back to production for missing buckets or failed daily reads.
    static let quotaSummaryURLs = Array(cloudCodeURLs.reversed())
    static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"

    static let loadCodeAssistPayload = Data(
        #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#.utf8
    )

    static let clientUserAgent: String = {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=\(arch))"
    }()

    /// In-memory refreshed access tokens, keyed by token file path.
    private actor TokenCache {
        struct Entry {
            let accessToken: String
            let expiresAt: Date
        }
        private var entries: [String: Entry] = [:]

        func validToken(for key: String, now: Date) -> String? {
            guard let entry = entries[key], entry.expiresAt > now.addingTimeInterval(60) else { return nil }
            return entry.accessToken
        }

        func store(_ token: String, expiresAt: Date, for key: String) {
            entries[key] = Entry(accessToken: token, expiresAt: expiresAt)
        }

        func clear(for key: String) {
            entries.removeValue(forKey: key)
        }
    }

    private static let cache = TokenCache()

    /// Fetches usage for every discovered local Gemini / Antigravity login.
    /// Returns an empty list when no local login exists.
    static func fetchAll(home: URL = Shell.home) async -> [Account] {
        let tokens = GeminiTokenStore.discover(home: home)
        guard !tokens.isEmpty else { return [] }

        var results: [Account] = []
        for (index, token) in tokens.enumerated() {
            let account = await fetch(token, isActive: index == 0, total: tokens.count)
            results.append(account)
        }
        return results
    }

    static func fetch(_ record: GeminiTokenRecord, isActive: Bool, total: Int) async -> Account {
        let now = Date.now
        let accountID = "gemini-\(record.accountKey)"
        let customName = GeminiTokenStore.customName(for: accountID)
        let fallbackName = customName ?? defaultDisplayName(email: record.email, total: total)

        do {
            var accessToken = try await resolveAccessToken(for: record, forceRefresh: false, now: now)
            let loadData: Data
            do {
                loadData = try await loadCodeAssist(token: accessToken)
            } catch is TokenRefusedError {
                await cache.clear(for: record.path)
                accessToken = try await resolveAccessToken(for: record, forceRefresh: true, now: now)
                loadData = try await loadCodeAssist(token: accessToken)
            }

            let plan = GeminiUsageMapper.parseLoadCodeAssistPlan(loadData) ?? ""
            let project = GeminiUsageMapper.parseProject(loadData)

            var email = record.email ?? ""
            if email.isEmpty {
                email = (try? await fetchEmail(token: accessToken)) ?? ""
            }
            let displayName = customName ?? defaultDisplayName(email: email.isEmpty ? nil : email, total: total)

            let summaryBodies: [Data]
            do {
                summaryBodies = try await quotaSummary(token: accessToken, project: project)
            } catch is TokenRefusedError {
                await cache.clear(for: record.path)
                accessToken = try await resolveAccessToken(for: record, forceRefresh: true, now: now)
                summaryBodies = try await quotaSummary(token: accessToken, project: project)
            }

            guard let windows = GeminiUsageMapper.parseQuotaSummaries(summaryBodies, now: .now), !windows.isEmpty else {
                return Account(
                    id: accountID, provider: .gemini, slot: nil, name: displayName,
                    email: email, plan: plan, isActive: isActive, activeIdentityVerified: true,
                    disabled: false, windows: [], problem: "Gemini usage response could not be read.",
                    fetchedAt: .now
                )
            }

            return Account(
                id: accountID, provider: .gemini, slot: nil, name: displayName,
                email: email, plan: plan, isActive: isActive, activeIdentityVerified: true,
                disabled: false, windows: windows, problem: nil, fetchedAt: .now
            )
        } catch {
            return Account(
                id: accountID, provider: .gemini, slot: nil, name: fallbackName,
                email: record.email ?? "", plan: "", isActive: isActive, activeIdentityVerified: false,
                disabled: false, windows: [], problem: error.localizedDescription, fetchedAt: nil
            )
        }
    }

    private static func defaultDisplayName(email: String?, total: Int) -> String {
        if total <= 1 { return "Gemini" }
        if let email, let prefix = email.split(separator: "@").first, !prefix.isEmpty {
            return String(prefix)
        }
        return "Gemini"
    }

    private struct TokenRefusedError: Error {}

    private static func resolveAccessToken(for record: GeminiTokenRecord, forceRefresh: Bool, now: Date) async throws -> String {
        if !forceRefresh {
            if let expiry = record.expiresAt, expiry > now.addingTimeInterval(60), !record.accessToken.isEmpty {
                return record.accessToken
            }
            if let cached = await cache.validToken(for: record.path, now: now) {
                return cached
            }
            if record.refreshToken == nil, !record.accessToken.isEmpty {
                return record.accessToken
            }
        }
        guard let refreshToken = record.refreshToken, !refreshToken.isEmpty else {
            throw ShellError.failed("Gemini sign-in expired. Sign in to Antigravity again.")
        }
        let refreshed = try await refreshAccessToken(refreshToken, now: now)
        await cache.store(refreshed.accessToken, expiresAt: refreshed.expiresAt, for: record.path)
        return refreshed.accessToken
    }

    private static func refreshAccessToken(_ refreshToken: String, now: Date) async throws -> (accessToken: String, expiresAt: Date) {
        guard let oauth = loadOAuthClientConfig() else {
            throw ShellError.failed("Gemini access token expired. Open T3 Code or Antigravity to refresh it.")
        }
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: oauth.clientID),
            URLQueryItem(name: "client_secret", value: oauth.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ShellError.failed("Gemini token refresh returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ShellError.failed("Gemini sign-in expired. Sign in to Antigravity again.")
            }
            throw ShellError.failed("Gemini token refresh failed (HTTP \(http.statusCode)).")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return (decoded.access_token, now.addingTimeInterval(decoded.expires_in ?? 3600))
    }

    private static func fetchEmail(token: String) async throws -> String? {
        var request = URLRequest(url: userInfoURL, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        struct UserInfo: Decodable { let email: String? }
        return try? JSONDecoder().decode(UserInfo.self, from: data).email
    }

    private static func loadCodeAssist(token: String) async throws -> Data {
        for base in cloudCodeURLs {
            guard let url = URL(string: base + loadCodeAssistPath) else { continue }
            let request = cloudCodeRequest(url: url, token: token, payload: loadCodeAssistPayload)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 { throw TokenRefusedError() }
            if http.statusCode == 403 {
                throw ShellError.failed("Gemini sign-in expired. Sign in to Antigravity again.")
            }
            if (200..<300).contains(http.statusCode) { return data }
        }
        throw ShellError.failed("Gemini usage is temporarily unavailable.")
    }

    private static func quotaSummary(token: String, project: String?) async throws -> [Data] {
        let body: [String: String] = project.map { ["project": $0] } ?? [:]
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var responses: [(status: Int, body: Data)] = []
        var transportError: Error?

        for (index, base) in quotaSummaryURLs.enumerated() {
            guard let url = URL(string: base + quotaSummaryPath) else { continue }
            let request = cloudCodeRequest(url: url, token: token, payload: payload)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                responses.append((http.statusCode, data))
                if index == 0, (200..<300).contains(http.statusCode), GeminiUsageMapper.isCompleteSummary(data) {
                    break
                }
            } catch {
                transportError = error
            }
        }

        if responses.isEmpty, let transportError { throw transportError }
        let bodies = responses.filter { (200..<300).contains($0.status) }.map(\.body)
        if !bodies.isEmpty { return bodies }
        if responses.contains(where: { $0.status == 401 }) { throw TokenRefusedError() }
        if responses.contains(where: { $0.status == 403 }) {
            throw ShellError.failed("Google reports no Antigravity quota access for this account.")
        }
        if responses.contains(where: { $0.status == 429 }) {
            throw ShellError.failed("Google rate-limited Gemini usage reads. Try again shortly.")
        }
        throw ShellError.failed("Gemini usage is temporarily unavailable.")
    }

    private static func cloudCodeRequest(url: URL, token: String, payload: Data) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = payload
        return request
    }
}

/// A discovered local Antigravity OAuth token record.
struct GeminiTokenRecord: Equatable {
    let path: String
    let email: String?
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let modifiedAt: Date

    var accountKey: String {
        if let email, !email.isEmpty {
            return email.lowercased().replacingOccurrences(of: "[^a-z0-9._@-]", with: "_", options: .regularExpression)
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

enum GeminiTokenStore {
    private static let namesKey = "geminiAccountNames.v1"

    static func customName(for accountID: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        guard let value = map[accountID]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func setCustomName(_ name: String, for accountID: String) {
        var map = UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: accountID)
        } else {
            map[accountID] = trimmed
        }
        UserDefaults.standard.set(map, forKey: namesKey)
    }

    /// Finds local Antigravity OAuth token files, deduplicated by email and
    /// ordered newest first.
    static func discover(home: URL = Shell.home) -> [GeminiTokenRecord] {
        let fm = FileManager.default
        var urls: [URL] = []

        // 1. T3 Code's Antigravity ACP provider profiles
        let t3Root = home.appendingPathComponent(".t3-zip/userdata/providers/antigravity", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: t3Root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in entries {
                let candidate = dir.appendingPathComponent("antigravity-acp/antigravity-oauth-token")
                if fm.fileExists(atPath: candidate.path) { urls.append(candidate) }
            }
        }

        // 2. Standalone Antigravity CLI locations
        let cliCandidates = [
            home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
            home.appendingPathComponent(".gemini/jetski-standalone-oauth-token"),
        ]
        for candidate in cliCandidates where fm.fileExists(atPath: candidate.path) {
            urls.append(candidate)
        }

        let parsed = urls.compactMap(parseTokenFile)
        guard !parsed.isEmpty else { return [] }

        // Prefer records that identify an email. If we already have a fresh named
        // Antigravity token, don't surface an unnamed legacy standalone token as a
        // duplicate second card.
        let named = parsed.filter { !($0.email ?? "").isEmpty }
        let pool = named.isEmpty ? parsed : named

        var byKey: [String: GeminiTokenRecord] = [:]
        for record in pool {
            let key = record.accountKey
            if let existing = byKey[key] {
                let existingRank = existing.expiresAt ?? existing.modifiedAt
                let candidateRank = record.expiresAt ?? record.modifiedAt
                if candidateRank > existingRank { byKey[key] = record }
            } else {
                byKey[key] = record
            }
        }

        return byKey.values.sorted {
            ($0.expiresAt ?? $0.modifiedAt) > ($1.expiresAt ?? $1.modifiedAt)
        }
    }

    static func parseTokenFile(_ url: URL) -> GeminiTokenRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct TokenFile: Decodable {
            struct Token: Decodable {
                let access_token: String?
                let refresh_token: String?
                let expiry: String?
            }
            let token: Token?
            let id_token_email: String?
        }
        guard let decoded = try? JSONDecoder().decode(TokenFile.self, from: data),
              let token = decoded.token else { return nil }
        let access = token.access_token ?? ""
        let refresh = token.refresh_token?.isEmpty == false ? token.refresh_token : nil
        guard !access.isEmpty || refresh != nil else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return GeminiTokenRecord(
            path: url.path,
            email: decoded.id_token_email?.trimmingCharacters(in: .whitespacesAndNewlines),
            accessToken: access,
            refreshToken: refresh,
            expiresAt: token.expiry.flatMap { Format.date($0) },
            modifiedAt: mtime
        )
    }
}

/// Parses Cloud Code `loadCodeAssist` and `retrieveUserQuotaSummary` responses.
enum GeminiUsageMapper {
    static let summaryBuckets: [(bucketID: String, label: String, windowMinutes: Double)] = [
        ("gemini-weekly", "Week", 10080),
        ("gemini-5h", "5h", 300),
    ]

    private static let argonGroupName = "Gemini 4 Argon"

    static let paidTierPlans: [String: String] = [
        "g1-pro-tier": "Pro",
        "g1-ultra-tier": "Ultra",
        "g1-ultra-lite-tier": "Ultra Lite",
    ]

    static func parseLoadCodeAssistPlan(_ data: Data) -> String? {
        guard let envelope = try? JSONDecoder().decode(CCLoadEnvelope.self, from: data) else { return nil }
        if let id = envelope.paidTier?.id, let plan = paidTierPlans[id] { return plan }
        return formatPlan(envelope.paidTier?.name ?? envelope.currentTier?.name)
    }

    static func parseProject(_ data: Data) -> String? {
        guard let raw = (try? JSONDecoder().decode(CCLoadEnvelope.self, from: data))?.cloudaicompanionProject?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    static func formatPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("ultra lite") { return "Ultra Lite" }
        if lower.contains("ultra") { return "Ultra" }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("free") || lower == "antigravity" { return "Free" }
        return trimmed
    }

    static func isCompleteSummary(_ data: Data) -> Bool {
        guard let groups = summaryGroups(data) else { return false }
        let shared = groups.filter { $0.displayName != argonGroupName }
        let usable = Set(shared.flatMap { $0.buckets ?? [] }.compactMap { bucket in
            bucket.remainingFraction?.isFinite == true ? bucket.bucketId : nil
        })
        return summaryBuckets.allSatisfy { usable.contains($0.bucketID) }
    }

    static func parseQuotaSummaries(_ bodies: [Data], now: Date = .now) -> [UsageWindow]? {
        let groupLists = bodies.compactMap(summaryGroups)
        guard !groupLists.isEmpty else { return nil }

        var pooled: [String: (fraction: Double, resetTime: Date?)] = [:]
        for bucket in groupLists.joined().filter({ $0.displayName != argonGroupName }).flatMap({ $0.buckets ?? [] }) {
            guard let id = bucket.bucketId, summaryBuckets.contains(where: { $0.bucketID == id }) else { continue }
            guard pooled[id] == nil else { continue }
            guard let fraction = bucket.remainingFraction, fraction.isFinite else { continue }
            pooled[id] = (fraction, bucket.resetTime.flatMap { Format.date($0) })
        }

        var windows: [UsageWindow] = summaryBuckets.compactMap { spec in
            guard let entry = pooled[spec.bucketID] else { return nil }
            return makeWindow(label: spec.label, fraction: entry.fraction, resetTime: entry.resetTime, windowMinutes: spec.windowMinutes, now: now)
        }

        if let argon = groupLists.lazy.compactMap({ argonWeeklyWindow($0, now: now) }).first {
            if let sessionIndex = windows.firstIndex(where: { $0.label == "5h" }) {
                windows.insert(argon, at: sessionIndex)
            } else {
                windows.append(argon)
            }
        }
        return windows
    }

    private static func argonWeeklyWindow(_ groups: [QuotaSummaryGroup], now: Date) -> UsageWindow? {
        let argonGroups = groups.filter { $0.displayName == argonGroupName }
        guard !argonGroups.isEmpty else { return nil }
        let weekly = argonGroups.flatMap { $0.buckets ?? [] }.filter { $0.window == "weekly" }
        guard weekly.count == 1, let bucket = weekly.first,
              let id = bucket.bucketId, !id.isEmpty,
              !summaryBuckets.contains(where: { $0.bucketID == id }),
              !bucket.hasInvalidDisabledFlag,
              bucket.disabled != true,
              let fraction = bucket.remainingFraction, fraction.isFinite else { return nil }
        return makeWindow(
            label: "Argon",
            fraction: fraction,
            resetTime: bucket.resetTime.flatMap { Format.date($0) },
            windowMinutes: 10080,
            now: now
        )
    }

    private static func makeWindow(label: String, fraction: Double, resetTime: Date?, windowMinutes: Double, now: Date) -> UsageWindow {
        let clamped = max(0, min(1, fraction))
        let usedPct = (1 - clamped) * 100
        let expected: Double?
        let projected: Date?
        let willLast: Bool?
        if windowMinutes >= 10080, let resetTime, resetTime > now {
            let length = windowMinutes * 60
            let elapsed = now.timeIntervalSince(resetTime.addingTimeInterval(-length))
            if elapsed > 0, length > 0 {
                let exp = min(100, elapsed / length * 100)
                expected = exp
                if usedPct > 0 {
                    let rate = usedPct / elapsed
                    let remaining = (100 - usedPct) / rate
                    let date = now.addingTimeInterval(remaining)
                    projected = date < resetTime ? date : nil
                    willLast = date >= resetTime
                } else {
                    projected = nil
                    willLast = true
                }
            } else {
                expected = nil; projected = nil; willLast = nil
            }
        } else {
            expected = nil; projected = nil; willLast = nil
        }
        return UsageWindow(
            label: label,
            pct: usedPct,
            resetsAt: resetTime,
            expectedPct: expected,
            projectedExhaustion: projected,
            willLastToReset: willLast,
            windowMinutes: windowMinutes
        )
    }

    private static func summaryGroups(_ data: Data) -> [QuotaSummaryGroup]? {
        guard let envelope = try? JSONDecoder().decode(QuotaSummaryEnvelope.self, from: data) else { return nil }
        return envelope.response?.groups ?? envelope.groups
    }
}

private struct QuotaSummaryEnvelope: Decodable {
    let response: QuotaSummaryRoot?
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryRoot: Decodable {
    let groups: [QuotaSummaryGroup]?
}

private struct QuotaSummaryGroup: Decodable {
    let displayName: String?
    let buckets: [QuotaSummaryBucket]?

    private enum CodingKeys: String, CodingKey { case displayName, buckets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        buckets = try container.decodeIfPresent([QuotaSummaryBucket].self, forKey: .buckets)
    }
}

private struct QuotaSummaryBucket: Decodable {
    let bucketId: String?
    let remainingFraction: Double?
    let resetTime: String?
    let window: String?
    let disabled: Bool?
    let hasInvalidDisabledFlag: Bool

    private enum CodingKeys: String, CodingKey { case bucketId, remainingFraction, resetTime, window, disabled }

    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .bucketId)) ?? nil }
        remainingFraction = container.flatMap { (try? $0.decodeIfPresent(Double.self, forKey: .remainingFraction)) ?? nil }
        resetTime = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .resetTime)) ?? nil }
        window = container.flatMap { (try? $0.decodeIfPresent(String.self, forKey: .window)) ?? nil }
        do {
            disabled = try container?.decodeIfPresent(Bool.self, forKey: .disabled)
            hasInvalidDisabledFlag = false
        } catch {
            disabled = nil
            hasInvalidDisabledFlag = true
        }
    }
}

private struct CCLoadEnvelope: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: Tier?
    let paidTier: Tier?

    struct Tier: Decodable {
        let id: String?
        let name: String?
    }
}
