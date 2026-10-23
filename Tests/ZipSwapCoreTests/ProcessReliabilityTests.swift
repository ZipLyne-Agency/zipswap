import Foundation
import Darwin
import XCTest
@testable import ZipSwapCore
import HandoffCore

final class ProcessReliabilityTests: XCTestCase {
    private func script(_ source: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-process-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.py")
        try Data(source.utf8).write(to: file)
        return (directory, file)
    }
    func testTimeoutKillsAnIgnoringParentAndItsDescendant() async throws {
        let (directory, file) = try script(#"""
        import os,signal,time,json,sys
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        child=os.fork()
        if child:
            with open(sys.argv[1],'w') as f: json.dump([os.getpid(),child],f)
        while True: time.sleep(.05)
        """#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = directory.appendingPathComponent("pids.json")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await Shell.run("python3", [file.path, ids.path], timeout: 0.5)
            XCTFail("Ignoring SIGTERM must still time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too long")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        let pids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: ids))
        for pid in pids {
            let result = try await Shell.run("ps", ["-p", String(pid), "-o", "stat="], timeout: 2)
            XCTAssertTrue(result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result.out.trimmingCharacters(in: .whitespaces).hasPrefix("Z"), "No owned descendant may keep executing")
        }
    }
    func testCancellationStopsAnActiveChild() async throws {
        let (directory, file) = try script("import os,time,sys\nopen(sys.argv[1],'w').write(str(os.getpid()))\ntime.sleep(60)\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task { try await Shell.run("python3", [file.path, pidFile.path], timeout: 90) }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !FileManager.default.fileExists(atPath: pidFile.path) && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testOutputFloodIsTerminatedAtTheBufferLimit() async throws {
        do { _ = try await Shell.run("yes", [], timeout: 5); XCTFail("Unbounded output must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("output limit")) }
    }
    func testLineFramingRejectsAnUnterminatedOversizedMessage() {
        let reader = LineReader()
        XCTAssertTrue(reader.feed(Data(repeating: 65, count: 1_048_577)).isEmpty)
        XCTAssertTrue(reader.overflow)
        XCTAssertTrue(reader.feed(Data("{}\n".utf8)).isEmpty)
    }
    func testInheritedIdentityAndBillingOverridesAreRemoved() {
        let keys = ["CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY"]
        let environment = Shell.environment(base: Dictionary(uniqueKeysWithValues: keys.map { ($0, "synthetic") }))
        for key in keys { XCTAssertNil(environment[key]) }
        XCTAssertEqual(Shell.environment(["CODEX_HOME": "/tmp/explicit"], base: [:])["CODEX_HOME"], "/tmp/explicit")
    }
    func testEngineFailureBudgetAndBackoffSurviveEncoding() throws {
        let now = Date()
        var policy = EngineRecovery()
        XCTAssertNotNil(policy.failed(at: now))
        policy = try JSONDecoder().decode(EngineRecovery.self, from: JSONEncoder().encode(policy))
        for index in 1..<4 { XCTAssertNotNil(policy.failed(at: now.addingTimeInterval(Double(index)))) }
        XCTAssertNil(policy.failed(at: now.addingTimeInterval(4)))
        XCTAssertNotNil(policy.failed(at: now.addingTimeInterval(3601)))
    }
}
