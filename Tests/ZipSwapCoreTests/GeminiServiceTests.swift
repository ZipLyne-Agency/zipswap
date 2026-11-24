import Foundation
import Testing
@testable import ZipSwapCore

struct GeminiServiceTests {
    @Test func parsesLoadCodeAssistPaidTierAndProject() {
        let json = Data("""
        {
          "paidTier": {
            "id": "g1-ultra-lite-tier",
            "name": "Google AI Ultra"
          },
          "currentTier": {
            "id": "free-tier",
            "name": "Antigravity"
          },
          "cloudaicompanionProject": "aicode-consumers"
        }
        """.utf8)

        #expect(GeminiUsageMapper.parseLoadCodeAssistPlan(json) == "Ultra Lite")
        #expect(GeminiUsageMapper.parseProject(json) == "aicode-consumers")
    }

    @Test func fallsBackToCurrentTierWhenPaidTierIsAbsent() {
        let json = Data("""
        {
          "currentTier": {
            "id": "free-tier",
            "name": "Antigravity"
          }
        }
        """.utf8)

        #expect(GeminiUsageMapper.parseLoadCodeAssistPlan(json) == "Free")
        #expect(GeminiUsageMapper.parseProject(json) == nil)
    }

    @Test func parsesWeeklyAndFiveHourGeminiBucketsAndIgnoresThirdParty() throws {
        let now = try #require(Format.date("2026-11-24T10:15:00Z"))
        let json = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "window": "weekly",
                  "resetTime": "2026-11-30T20:03:15Z",
                  "remainingFraction": 0.91
                },
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "resetTime": "2026-11-24T14:13:59Z",
                  "remainingFraction": 0.82
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-weekly",
                  "window": "weekly",
                  "resetTime": "2026-12-01T10:16:11Z",
                  "remainingFraction": 1
                }
              ]
            }
          ]
        }
        """.utf8)

        #expect(GeminiUsageMapper.isCompleteSummary(json))
        let windows = try #require(GeminiUsageMapper.parseQuotaSummaries([json], now: now))
        #expect(windows.map(\.label) == ["Week", "5h"])
        #expect(abs(windows[0].pct - 9.0) < 0.001)
        #expect(windows[0].windowMinutes == 10080)
        #expect(windows[0].expectedPct != nil)
        #expect(abs(windows[1].pct - 18.0) < 0.001)
        #expect(windows[1].windowMinutes == 300)
        #expect(windows[1].expectedPct == nil)
    }

    @Test func mergesDailyAndProductionQuotaSummaries() throws {
        let daily = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "resetTime": "2026-11-24T14:13:59Z",
                  "remainingFraction": 0.6
                }
              ]
            }
          ]
        }
        """.utf8)

        let prod = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-weekly",
                  "window": "weekly",
                  "resetTime": "2026-11-30T20:03:15Z",
                  "remainingFraction": 0.75
                },
                {
                  "bucketId": "gemini-5h",
                  "window": "5h",
                  "resetTime": "2026-11-24T15:16:11Z",
                  "remainingFraction": 1.0
                }
              ]
            }
          ]
        }
        """.utf8)

        #expect(!GeminiUsageMapper.isCompleteSummary(daily))
        let windows = try #require(GeminiUsageMapper.parseQuotaSummaries([daily, prod]))
        #expect(windows.map(\.label) == ["Week", "5h"])
        #expect(abs(windows[0].pct - 25.0) < 0.001)
        #expect(abs(windows[1].pct - 40.0) < 0.001)
    }

    @Test func includesActiveArgonWeeklyAndDropsDisabledArgon() throws {
        let activeArgon = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                { "bucketId": "gemini-weekly", "remainingFraction": 0.9 },
                { "bucketId": "gemini-5h", "remainingFraction": 0.8 }
              ]
            },
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                { "bucketId": "argon-weekly", "window": "weekly", "remainingFraction": 0.5, "disabled": false }
              ]
            }
          ]
        }
        """.utf8)

        let disabledArgon = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                { "bucketId": "gemini-weekly", "remainingFraction": 0.9 },
                { "bucketId": "gemini-5h", "remainingFraction": 0.8 }
              ]
            },
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                { "bucketId": "argon-weekly", "window": "weekly", "remainingFraction": 0.5, "disabled": true }
              ]
            }
          ]
        }
        """.utf8)

        let withArgon = try #require(GeminiUsageMapper.parseQuotaSummaries([activeArgon]))
        #expect(withArgon.map(\.label) == ["Week", "Argon", "5h"])
        #expect(abs(withArgon[1].pct - 50.0) < 0.001)

        let withoutArgon = try #require(GeminiUsageMapper.parseQuotaSummaries([disabledArgon]))
        #expect(withoutArgon.map(\.label) == ["Week", "5h"])
    }

    @Test func discoversAndDeduplicatesTokensPreferringNamedNewest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let t3Older = root.appendingPathComponent(".t3-zip/userdata/providers/antigravity/prof1/antigravity-acp")
        let t3Newer = root.appendingPathComponent(".t3-zip/userdata/providers/antigravity/prof2/antigravity-acp")
        let geminiDir = root.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: t3Older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: t3Newer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)

        try Data("""
        {"id_token_email":"user@example.com","token":{"access_token":"old","refresh_token":"r1","expiry":"2026-11-24T10:00:00Z"}}
        """.utf8).write(to: t3Older.appendingPathComponent("antigravity-oauth-token"))

        try Data("""
        {"id_token_email":"user@example.com","token":{"access_token":"new","refresh_token":"r2","expiry":"2026-11-24T13:00:00Z"}}
        """.utf8).write(to: t3Newer.appendingPathComponent("antigravity-oauth-token"))

        try Data("""
        {"token":{"access_token":"legacy","refresh_token":"r3","expiry":"2026-08-20T10:00:00Z"}}
        """.utf8).write(to: geminiDir.appendingPathComponent("jetski-standalone-oauth-token"))

        let discovered = GeminiTokenStore.discover(home: root)
        #expect(discovered.count == 1)
        #expect(discovered[0].email == "user@example.com")
        #expect(discovered[0].accessToken == "new")
    }
}
