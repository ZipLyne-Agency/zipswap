import Foundation
import XCTest
@testable import ZipSwapCore

final class CredentialStoreTests: XCTestCase {
    struct Fixture {
        let root: URL
        let store: CodexStore
        let a = CodexStoredAccount(id: UUID().uuidString.lowercased(), name: "One", email: "one@example.test", accountId: "one", plan: "pro")
        let b = CodexStoredAccount(id: UUID().uuidString.lowercased(), name: "Two", email: "two@example.test", accountId: "two", plan: "pro")
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("zipswap-store-\(UUID())")
            store = CodexStore(root: root.appendingPathComponent("store"), liveHome: root.appendingPathComponent("live"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func auth(_ id: String, refresh: String = "2026-10-23T10:00:00Z", generation: String = "synthetic") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": id, "access_token": generation, "refresh_token": "synthetic"], "last_refresh": refresh])
        }
        func seed() throws {
            try PrivateFile.write(auth("one"), to: store.liveAuth)
            try PrivateFile.write(auth("one"), to: store.home(for: a.id).appendingPathComponent("auth.json"))
            try PrivateFile.write(auth("two"), to: store.home(for: b.id).appendingPathComponent("auth.json"))
            try store.saveIndex([a,b], replacing: [])
        }
    }
    func testIndexRejectsLostUpdatesAndCorruption() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        XCTAssertThrowsError(try f.store.saveIndex([], replacing: []))
        XCTAssertEqual(try f.store.loadIndex(), [f.a,f.b])
        try PrivateFile.write(Data("{".utf8), to: f.store.indexURL)
        XCTAssertThrowsError(try f.store.loadIndex())
    }
    func testBackupRestoresOnlyAnIndexWithMatchingCredentials() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        var renamed = f.a; renamed.name = "Renamed"
        try f.store.saveIndex([renamed,f.b], replacing: [f.a,f.b])
        try PrivateFile.write(Data("broken".utf8), to: f.store.indexURL)
        try f.store.restoreIndexBackup()
        XCTAssertEqual(try f.store.loadIndex(), [f.a,f.b])
        try FileManager.default.removeItem(at: f.store.home(for: f.a.id).appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try f.store.restoreIndexBackup())
    }
    func testMismatchedStoredCredentialCannotReplaceTheLiveLogin() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        try PrivateFile.write(f.auth("wrong"), to: f.store.home(for: f.b.id).appendingPathComponent("auth.json"))
        XCTAssertThrowsError(try f.store.activate(f.b, expectedLiveID: "one"))
        XCTAssertEqual(try f.store.credential(f.store.liveAuth)?.accountID, "one")
    }
    func testAnExternalLoginIsNeverRolledBack() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        try PrivateFile.write(f.auth("external"), to: f.store.liveAuth)
        XCTAssertThrowsError(try f.store.activate(f.b, expectedLiveID: "one"))
        XCTAssertEqual(try f.store.credential(f.store.liveAuth)?.accountID, "external")
    }
    func testSynchronizationCannotOverwriteANewerRefreshGeneration() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        let newer = try f.auth("one", refresh: "2026-10-23T11:00:00Z", generation: "synthetic-newer")
        let saved = f.store.home(for: f.a.id).appendingPathComponent("auth.json")
        try PrivateFile.write(newer, to: saved)
        var accounts = [f.a,f.b]
        try f.store.syncLive(into: &accounts)
        XCTAssertEqual(try Data(contentsOf: saved), newer)
    }
    func testAtomicWriteRejectsChangedGenerationAndUsesPrivatePermissions() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appendingPathComponent("private/state.json")
        try PrivateFile.write(Data("new".utf8), to: file)
        XCTAssertThrowsError(try PrivateFile.write(Data("stale".utf8), to: file, expected: Data("old".utf8), compare: true))
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testSymlinkAndNonFileInputsAreRejected() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
        XCTAssertThrowsError(try PrivateFile.readIfPresent(link))
        XCTAssertThrowsError(try PrivateFile.readIfPresent(f.root))
    }
    func testInterruptedRemovalRestoresBeforeIndexCommitAndCleansAfterIt() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        let nonce = UUID().uuidString.lowercased()
        let staging = f.store.root.appendingPathComponent(".remove-\(f.b.id)-\(nonce)")
        let journal = f.store.root.appendingPathComponent("removal.json")
        let data = try JSONSerialization.data(withJSONObject: ["accountID": f.b.id, "nonce": nonce])
        try FileManager.default.moveItem(at: f.store.home(for: f.b.id), to: staging)
        try PrivateFile.write(data, to: journal)
        try f.store.locked { try f.store.recoverPendingRemoval() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.store.home(for: f.b.id).appendingPathComponent("auth.json").path))
        try FileManager.default.moveItem(at: f.store.home(for: f.b.id), to: staging)
        try PrivateFile.write(data, to: journal)
        try f.store.saveIndex([f.a], replacing: [f.a,f.b])
        try f.store.locked { try f.store.recoverPendingRemoval() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try f.store.loadIndex(), [f.a])
    }
    func testExplicitOrphanRecoveryKeepsCredentialsAndTheDefaultLogin() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        try f.store.saveIndex([f.a], replacing: [f.a,f.b])
        XCTAssertEqual(try f.store.recoverSavedLogins(), 1)
        XCTAssertEqual(try f.store.loadIndex().count, 2)
        XCTAssertEqual(try f.store.credential(f.store.liveAuth)?.accountID, "one")
    }

    func testAnUnrelatedInvalidDefaultLoginDoesNotDisableSavedSubscriptionProfiles() throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed()
        for data in [Data("{".utf8), try JSONSerialization.data(withJSONObject: ["auth_mode": "apikey", "OPENAI_API_KEY": "synthetic-only"])] {
            try PrivateFile.write(data, to: f.store.liveAuth)
            var accounts = [f.a, f.b]
            try f.store.syncLive(into: &accounts)
            XCTAssertEqual(accounts, [f.a, f.b])
            XCTAssertEqual(try f.store.credential(f.store.home(for: f.a.id).appendingPathComponent("auth.json"))?.accountID, "one")
            XCTAssertThrowsError(try f.store.activate(f.b, expectedLiveID: nil))
            XCTAssertEqual(try Data(contentsOf: f.store.liveAuth), data)
        }
    }
}
