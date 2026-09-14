import Darwin
import Foundation
import SandboxRuntime

enum AccountlessDetachedImageObservation {
    /// The caller holds fresh EX and native/source locks through both reads.
    static func verify(image: URL, descriptor: Int32) async throws {
        let runner = SandboxProcessRunner()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["info", "-plist"], timeoutSeconds: 30, maximumOutputBytes: 4 * 1_048_576)
        guard result.exitCode == 0, !result.standardOutputTruncated, !result.standardErrorTruncated,
              try AccountlessAttachmentInventory(result.standardOutput).ownedTarget(image, ownerUID: 0) == nil else {
            throw AccountlessDiskError.cleanupUnproven
        }
        let openers = try await runner.run(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-Fpf", "--", image.path], timeoutSeconds: 30, maximumOutputBytes: 64 * 1024)
        try AccountlessImageOpeners.requireOnlyRetainedDescriptor(openers, pid: getpid(), descriptor: descriptor)
    }
}
