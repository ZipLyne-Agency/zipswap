import Foundation
import XCTest
@testable import ZipSwapCore
import HandoffCore

final class EngineRecoveryTests: XCTestCase {
    @MainActor func testStoppingAHealthyEngineDetachesBothPipesAndPreservesItsFailureBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-engine")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let suite = "zipswap-engine-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ZipSwapBridge")
        let child = OwnedProcess(supervisor: helper)
        let engine = ClaudeAutoEngine(executable: script, defaults: defaults, processFactory: { child })
        engine.start(threshold: 99)
        XCTAssertTrue(child.isRunning)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(child.isRunning)
        try await engine.pause()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while child.output.fileHandleForReading.readabilityHandler != nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(child.isRunning)
        XCTAssertFalse(child.didTimeOut)
        XCTAssertNil(child.output.fileHandleForReading.readabilityHandler)
        XCTAssertNil(child.errors.fileHandleForReading.readabilityHandler)
        XCTAssertNil(defaults.data(forKey: "claudeEngineRecovery.v1"))
    }
    func testAnExitedEngineActuallyRestartsAndStopCancelsFurtherRestarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-engine"), count = root.appendingPathComponent("starts")
        let quote = count.path.replacingOccurrences(of: "'", with: "'\\''")
        try Data("#!/bin/sh\nprintf 'start\\n' >> '\(quote)'\nexit 3\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let suite = "zipswap-engine-test-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let helper = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ZipSwapBridge")
        let engine = try await MainActor.run { ClaudeAutoEngine(executable: script, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), supervisor: helper) }
        await MainActor.run { engine.start(threshold: 99) }
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var starts = 0
        while starts < 2 && ProcessInfo.processInfo.systemUptime < deadline {
            starts = (try? String(contentsOf: count, encoding: .utf8).split(separator: "\n").count) ?? 0
            try await Task.sleep(for: .milliseconds(20))
        }
        await MainActor.run { engine.stop() }
        XCTAssertGreaterThanOrEqual(starts, 2)
        let running = await MainActor.run { engine.isRunning }
        let retryAt = await MainActor.run { engine.retryAt }
        XCTAssertFalse(running)
        XCTAssertNil(retryAt)
    }
}
