import Foundation
import XCTest
import Darwin
import HandoffCore
@testable import ZipSwapCore

final class WatchdogTests: XCTestCase {
    private func bridge() throws -> URL {
        let url = Bundle(for: WatchdogTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ZipSwapBridge")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        return url
    }
    func testSupervisionPreservesSuccessfulExitStatus() throws {
        let child = OwnedProcess(supervisor: try bridge())
        defer { child.stop(); child.closePipes() }
        let done = DispatchSemaphore(value: 0)
        child.onExit = { _ in done.signal() }
        try child.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf verified"], environment: Shell.environment(), lifetime: 3)
        try child.input.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + 4) == .success else { XCTFail("The supervised command must exit"); return }
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(String(decoding: child.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "verified")
    }
    func testOwnerDeathKillsAnIgnoringCommandAndItsDescendant() async throws {
        try await verifyOwnerDeath(ownerOnly: false)
    }
    func testOwnerBoundServiceIsCleanedUpWithoutADeadline() async throws {
        try await verifyOwnerDeath(ownerOnly: true)
    }
    private func verifyOwnerDeath(ownerOnly: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-watchdog-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = root.appendingPathComponent("owner.py"), leaf = root.appendingPathComponent("leaf.py")
        let ownerPID = root.appendingPathComponent("owner.pid"), identity = root.appendingPathComponent("identity.json"), leafPIDs = root.appendingPathComponent("leaf.json")
        try Data(#"""
        import os,sys,subprocess,time,json
        bridge,leaf,owner_pid,identity,leaf_pids,mode=sys.argv[1:]
        open(owner_pid,'w').write(str(os.getpid()))
        until=time.monotonic()+5
        while not os.path.exists(identity) and time.monotonic()<until: time.sleep(.01)
        record=json.load(open(identity))
        bounds=['--owner-only'] if mode=='owner' else ['--lifetime','5']
        child=subprocess.Popen([bridge,'supervise']+bounds+['--termination-grace','0.1','--owner-pid',str(os.getpid()),'--owner-start',str(record['start']),'--',sys.executable,leaf,leaf_pids],start_new_session=True)
        while not os.path.exists(leaf_pids) and time.monotonic()<until: time.sleep(.01)
        # Simulate a disappearing app. The command has a different group, so
        # only its watchdog can clean it after this owner exits.
        sys.exit(0)
        """#.utf8).write(to: owner)
        try Data(#"""
        import os,sys,signal,time,json
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        descendant=os.fork()
        if descendant: json.dump([os.getpid(),descendant],open(sys.argv[1],'w'))
        while True: time.sleep(.05)
        """#.utf8).write(to: leaf)
        let helper = try bridge()
        let task = Task { try await Shell.run("python3", [owner.path, helper.path, leaf.path, ownerPID.path, identity.path, leafPIDs.path, ownerOnly ? "owner" : "bounded"], timeout: 8) }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !FileManager.default.fileExists(atPath: ownerPID.path) && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: ownerPID, encoding: .utf8)))
        let start = try XCTUnwrap(ProcessIdentity.capture(pid)).startTime
        try JSONSerialization.data(withJSONObject: ["start": start]).write(to: identity)
        let result = try await task.value
        XCTAssertEqual(result.status, 0)
        let pids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: leafPIDs))
        for pid in pids { XCTAssertNil(ProcessIdentity.capture(pid), "The watchdog must clean every owned descendant") }
    }
}
