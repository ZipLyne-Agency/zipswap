import Foundation

@main
struct UsageRegressionTests {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError(message) }
        }
        func date(_ value: String) -> Date { Format.date(value)! }

        // Pinning TZ=UTC when running this test proves the display uses Israel.
        expect(Format.hm(date("2026-10-23T17:00:00.192422+00:00")) == "20:00", "Friday reset must be 20:00 Israel time")
        expect(Format.hm(date("2026-10-25T10:00:00Z")) == "12:00", "Sunday reset must use Israel standard time")
        expect(Format.hm(date("2026-10-24T22:30:00Z")) == "01:30", "Before Israel DST ends")
        expect(Format.hm(date("2026-10-24T23:30:00Z")) == "01:30", "After Israel DST ends")
        expect(Format.hm(date("2026-10-27T14:00:00Z")) == "16:00", "Next week's reset must be 16:00")
        expect(Format.date("2026-10-23T20:00:00+03:00") == date("2026-10-23T17:00:00Z"), "Respect timestamp offsets")
        expect(Format.date(1_792_774_800) == date("2026-10-23T17:00:00Z"), "Parse Unix reset timestamps")
        expect(Format.clock(date("2026-10-23T21:30:00Z"), now: date("2026-10-23T06:00:00Z")) == "Tomorrow 00:30", "Day label must use Israel midnight")
        expect(Format.backTime(date("2026-10-23T21:30:00Z"), now: date("2026-10-23T06:00:00Z")) == "Sat 00:30", "Weekday must use Israel time")
        expect(Format.clock(date("2026-10-25T10:00:00Z"), now: date("2026-10-23T06:00:00Z")) == "Oct 25 12:00", "Absolute date must use Israel time")
        expect(Format.short(date("2026-10-25T10:00:00Z"), now: date("2026-10-23T06:00:00Z")) == "2d 4h", "Countdown measures real elapsed time across DST")
        expect(Format.backTime(date("2026-10-26T06:59:59.785300Z"), now: date("2026-10-23T06:00:00Z")) == "Mon 09:00", "Round reset display to the provider's minute")
        expect(Format.resetClock(date("2026-10-23T16:59:59.785300Z"), now: date("2026-10-23T06:00:00Z")) == "Today 20:00", "Near-hour reset must not appear one minute early")
        expect(Format.resetClock(date("2026-10-23T17:00:00.192422Z"), now: date("2026-10-23T06:00:00Z")) == "Today 20:00", "Provider timestamp jitter must not add a minute")
        expect(abs(date("2026-10-23T16:59:59.785300Z").timeIntervalSince1970 - 1_792_774_799.7853) < 0.001, "Preserve fractional reset precision")

        let inherited = Shell.environment([:], base: [
            "CLAUDE_CONFIG_DIR": "/tmp/orca-profile", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/tmp/another-profile",
            "CODEX_HOME": "/tmp/agent-codex", "ANTHROPIC_API_KEY": "fake", "OTHER": "keep"
        ])
        expect(inherited["CLAUDE_CONFIG_DIR"] == nil && inherited["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil, "Machine account manager must ignore launcher Claude profile")
        expect(inherited["CODEX_HOME"] == nil && inherited["ANTHROPIC_API_KEY"] == nil, "Account manager must ignore inherited auth overrides")
        expect(inherited["OTHER"] == "keep", "Preserve unrelated process configuration")
        expect(Shell.environment(["CODEX_HOME": "/tmp/selected-account"], base: [:])["CODEX_HOME"] == "/tmp/selected-account", "Explicit per-account Codex home still works")

        let lastGood: [String: Any] = ["sevenDay": ["pct": 73.0, "resetsAt": "2026-10-27T14:00:00Z"]]
        let stale = ClaudeService.parse([
            "number": 4, "active": true, "usageStatus": "unavailable",
            "lastGoodUsage": lastGood, "lastGoodFetchedAt": "2026-10-22T22:30:53Z"
        ])
        expect(stale.stale && stale.weekly?.pct == 73, "Keep last known usage marked stale")
        expect(stale.problem == "Usage unavailable", "Explain failed fetch on active account")
        expect(stale.fetchedAt == date("2026-10-22T22:30:53Z"), "Retain actual measurement age")
        let unknown = ClaudeService.parse(["number": 1, "usageStatus": "future_failure"])
        expect(unknown.problem != nil, "Unknown failure statuses must remain visible")
        let fresh = ClaudeService.parse([
            "number": 1, "usageStatus": "ok", "usage": lastGood,
            "usageFetchedAt": "2026-10-23T06:46:42Z"
        ])
        expect(!fresh.stale && fresh.problem == nil, "Fresh usage must recover from failure")
        let throttled = ClaudeService.parse([
            "number": 4, "usageStatus": "unavailable", "usageError": "http-429",
            "usageRetryAt": "2026-10-23T08:14:51Z", "lastGoodUsage": lastGood,
            "lastGoodFetchedAt": "2026-10-22T22:30:53Z"
        ])
        expect(throttled.problem == "Usage throttled", "Explain throttling instead of a generic failure")
        expect(throttled.usageRetryAt == date("2026-10-23T08:14:51Z"), "Retain the provider retry deadline")
        expect(throttled.usageFreshness(now: date("2026-10-23T08:10:00Z")).contains("Retry in 4m"), "Show next retry once beside the account")
        expect(throttled.usageFreshness(now: date("2026-10-23T08:15:00Z")).contains("Retry due"), "A past retry does not promise successful recovery")
        let denied = ShellResult(status: 1, stdout: Data("{\"accounts\": []}".utf8), stderr: Data())
        do {
            _ = try ClaudeService.decode(denied)
            fatalError("Nonzero helper exit must fail even with valid JSON")
        } catch { checks += 1 }
        let malformed = ShellResult(status: 0, stdout: Data("{}".utf8), stderr: Data())
        do {
            _ = try ClaudeService.decode(malformed)
            fatalError("Incomplete output must not silently clear accounts")
        } catch { checks += 1 }
        print("Passed \(checks) usage and Israel-time checks")
    }
}
