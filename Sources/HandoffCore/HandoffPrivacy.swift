import Foundation
import CryptoKit

public enum HandoffPrivacy {
    public static func digest(_ context: String) -> String {
        SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func canonicalWorkspace(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    public static func allowed(_ cwd: String, settings: HandoffSettings) -> Bool {
        settings.approvedWorkspaces?.contains(canonicalWorkspace(cwd)) == true
    }
}
