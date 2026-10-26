import Foundation
import Darwin
import DarkbloomClusterProcess

/// The local equivalent of the fixed installed SSH owner command. No caller
/// arguments, arbitrary environment, script or shell expression crosses this API.
/// Only this Mac's typed lane count, optional synchronization choices and live
/// and checkpoint KV precision switches (short lowercase names, resolved by the
/// owner) are forwarded.
public struct ClusterLocalOwnerConfiguration: Sendable {
    public let installedDarkbloom: URL
    private let batchLanes: Int?
    private let fastSynchronization: Bool?
    private let eagerFenceCommit: Bool?
    private let kvQuantization: String?
    private let checkpointQuantization: String?

    public init(installedDarkbloom: URL, batchLanes: Int? = nil, fastSynchronization: Bool? = nil,
                eagerFenceCommit: Bool? = nil, kvQuantization: String? = nil, checkpointQuantization: String? = nil) throws {
        if let batchLanes, !(1...8).contains(batchLanes) {
            throw ClusterOwnerStateError.invalid("Installed local owner batch lanes must be 1...8")
        }
        for name in [kvQuantization, checkpointQuantization].compactMap({ $0 })
        where !(1...16).contains(name.utf8.count) || !name.utf8.allSatisfy({ (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) }) {
            throw ClusterOwnerStateError.invalid("Installed local owner KV precision must be a short lowercase name")
        }
        let path = installedDarkbloom.path
        guard installedDarkbloom.isFileURL, path.hasPrefix("/"), path.utf8.count <= 1024,
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw ClusterOwnerStateError.invalid("Invalid installed local owner path")
        }
        self.installedDarkbloom = installedDarkbloom
        self.batchLanes = batchLanes
        self.fastSynchronization = fastSynchronization
        self.eagerFenceCommit = eagerFenceCommit
        self.kvQuantization = kvQuantization
        self.checkpointQuantization = checkpointQuantization
    }

    func launch() throws -> ClusterWorkerLaunch {
        var information = stat()
        guard lstat(installedDarkbloom.path, &information) == 0, information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(), information.st_nlink == 1,
              information.st_mode & 0o022 == 0, information.st_mode & 0o111 != 0 else {
            throw ClusterOwnerStateError.invalid("Installed local owner is unsafe or not executable")
        }
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        if let batchLanes { environment["DARKBLOOM_CLUSTER_BATCH_LANES"] = String(batchLanes) }
        if let fastSynchronization { environment["MLX_METAL_FAST_SYNCH"] = fastSynchronization ? "1" : "0" }
        if let eagerFenceCommit { environment["MLX_EAGER_FENCE_COMMIT"] = eagerFenceCommit ? "1" : "0" }
        if let kvQuantization { environment["DARKBLOOM_CBV2_KV_QUANTIZATION"] = kvQuantization }
        if let checkpointQuantization { environment["DARKBLOOM_CBV2_CHECKPOINT_QUANTIZATION"] = checkpointQuantization }
        return .init(executable: installedDarkbloom, arguments: ["cluster", "worker-owner", "--stdio"],
            environment: environment)
    }
}
