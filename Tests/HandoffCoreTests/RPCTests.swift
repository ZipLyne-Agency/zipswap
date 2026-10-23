import Foundation
import XCTest
@testable import HandoffCore

final class RPCTests: XCTestCase {
    private func connection(mode: String, lifetime: Double = 5) throws -> (CodexRPC, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-rpc-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("server.py")
        try Data(Self.server.utf8).write(to: script)
        let python = try XCTUnwrap(HandoffCommands.find("python3"))
        let rpc = try CodexRPC(executable: python, arguments: ["-u", script.path, mode],
                               environment: HandoffCommands.environment(), lifetime: lifetime)
        return (rpc, dir)
    }

    func testInitializeIsAcknowledgedBeforeInitializedAndRequests() throws {
        let (rpc, dir) = try connection(mode: "ok")
        defer { rpc.close(); try? FileManager.default.removeItem(at: dir) }
        let backend = LocalCodexBackend(rpc: rpc)
        try backend.preflight()
        XCTAssertEqual(backend.accountID, "fixture-account")
        let id = try backend.create(cwd: dir.path)
        try backend.inject(threadID: id, context: "fixture")
        try backend.name(threadID: id, name: "fixture")
        try backend.verify(threadID: id)
        XCTAssertTrue(HandoffPaths.validID(id))
    }

    func testAPIAuthAndExhaustedOrUnknownAllowanceAreRejected() throws {
        for mode in ["api", "exhausted", "unknown", "unknown-permission", "missing-identity"] {
            let (rpc, dir) = try connection(mode: mode)
            defer { rpc.close(); try? FileManager.default.removeItem(at: dir) }
            XCTAssertThrowsError(try LocalCodexBackend(rpc: rpc).preflight())
        }
    }

    func testRPCErrorIsNotMistakenForSuccessfulThread() throws {
        let (rpc, dir) = try connection(mode: "error")
        defer { rpc.close(); try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try rpc.call("thread/start")) { error in
            XCTAssertTrue((error as? CodexRPCError)?.rejectedBeforeExecution == true)
            XCTAssertFalse(error.localizedDescription.contains("secret-provider-detail"))
            XCTAssertTrue(error.localizedDescription.contains("thread/start"))
        }
    }

    func testTimeoutAndPrematureExitReturnFailure() throws {
        for mode in ["timeout", "exit"] {
            let (rpc, dir) = try connection(mode: mode, lifetime: 1)
            defer { rpc.close(); try? FileManager.default.removeItem(at: dir) }
            XCTAssertThrowsError(try rpc.call("thread/start"))
        }
    }

    static let server = #"""
    import sys,json,time
    mode=sys.argv[1]
    initialized=False
    acknowledged=False
    thread='12345678-1234-1234-1234-123456789abc'
    for line in sys.stdin:
        msg=json.loads(line)
        method=msg['method']
        if method=='initialize':
            time.sleep(0.03)
            print(json.dumps({'id':msg['id'],'result':{}}),flush=True)
            acknowledged=True
            continue
        if method=='initialized':
            assert acknowledged
            initialized=True
            continue
        assert initialized
        if method=='thread/start' and mode=='timeout':
            time.sleep(5)
        if method=='thread/start' and mode=='exit':
            sys.exit(0)
        if mode=='error':
            print(json.dumps({'id':msg['id'],'error':{'code':-32601,'message':'secret-provider-detail'}}),flush=True)
            continue
        result={}
        if method=='account/read': result={'account':{'type':'apiKey' if mode=='api' else 'chatgpt'}}
        if method=='account/rateLimits/read':
            result={'accountId':'fixture-account','ordinaryUsageAllowed':True,
                    'rateLimits':{'primary':{'usedPercent':100 if mode=='exhausted' else 10,
                                             'windowDurationMins':300,'resetsAt':1792755600}}}
            if mode=='unknown': result['rateLimits']={}
            if mode=='unknown-permission': result['ordinaryUsageAllowed']=None
            if mode=='missing-identity': result.pop('accountId')
        if method in ['thread/start','thread/read']: result={'thread':{'id':thread,'ephemeral':False}}
        print(json.dumps({'method':'ignored/notification','params':{}}),flush=True)
        print(json.dumps({'id':msg['id'],'result':result}),flush=True)
    """#
}
