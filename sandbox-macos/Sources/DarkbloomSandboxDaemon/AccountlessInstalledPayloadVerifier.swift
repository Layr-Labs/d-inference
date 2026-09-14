import Darwin
import Foundation
import SandboxRuntime

struct AccountlessInstalledPayloadVerifier {
    var verifySignature: (URL, String) throws -> Void = BaseGuestRelease.verifySignature

    func verify(dataDirectory: URL, plan: AccountlessInstallationPayloadPlan) throws {
        let root = try AccountlessOfflineDirectory(path: dataDirectory)
        let expected: [(String, UInt16, String)] = [
            ("usr/local/libexec/darkbloom-sandbox-guest", 0o755, plan.binding.payload.guestSHA256),
            ("usr/local/libexec/darkbloom-sandbox-bootstrap.sh", 0o755, plan.binding.payload.bootstrapSHA256),
            ("Library/LaunchDaemons/io.darkbloom.sandbox.guest.plist", 0o644, plan.binding.payload.launchdSHA256),
            ("private/etc/synthetic.d/io.darkbloom.sandbox", 0o644, BaseGuestRelease.digest(Data("workspace\n".utf8))),
        ]
        for (path, mode, hash) in expected {
            let directory = try root.descend((path as NSString).deletingLastPathComponent), name = (path as NSString).lastPathComponent
            let file = try directory.openFile(name, mode: mode, allowPublic: true)
            defer { close(file) }
            guard try BaseGuestRelease.copyAndHash(file, to: nil) == hash else { throw AccountlessInstallationError.releaseChanged }
            if path.hasSuffix("/darkbloom-sandbox-guest") {
                try verifySignature(dataDirectory.appendingPathComponent(path), "io.darkbloom.sandbox.guest")
            }
            try directory.requireNamed(file, name: name)
        }
        try root.requireBound(to: dataDirectory)
    }
}
