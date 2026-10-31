import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterProcess
@_spi(OwnerService) import DarkbloomClusterRemote

/// Local exclusion and bounded metadata custody only. Never a receipt for the
/// tensor payload. The native SDK loader still verifies actual payload hashes.
final class GLM5NextCalibrationInstalledOwnerResources {
    struct TransportSelection: Sendable {
        let matrixSHA256: String
        let coordinator: String
        let localInterface: String
        let device: String
    }
    struct Environment {
        let providerLock: URL
        let deviceDirectory: URL
        let orphanCheck: () throws -> Void
        let linkReady: (String) throws -> Void
        let requirePhysicalInterface: (String, String) throws -> Void

        static func production() throws -> Self {
            let paths = try ClusterUserPaths()
            let lock = BuildEnvironment.current.installDirectory(home: paths.homeDirectory)
                .appendingPathComponent("provider.pid.lock")
            // This finite path must own the real instance lock itself. An env
            // override must not create a second namespace beside a live provider.
            guard ProcessLifecycle.defaultPIDFile().appendingPathExtension("lock") == lock else {
                throw GLM5NextCalibrationDocument.invalid("Finite owner requires the canonical provider lock")
            }
            return Self(providerLock: lock, deviceDirectory: paths.deviceDirectory,
                orphanCheck: { try ClusterOrphanWiredGuard.check(role: "glm-finite-owner") },
                linkReady: { try ClusterLinkLaunchReadiness.waitForLink(device: $0) },
                requirePhysicalInterface: { device, interface in
                    let report = ClusterLinkReadinessProbe.inspectLocalLink(isolation: false)
                    guard report.devices.contains(where: { $0.device == device && $0.interface == interface }) else {
                        throw GLM5NextCalibrationDocument.invalid("Paired physical RDMA interface is unavailable")
                    }
                })
        }

        /// Isolated CPU fixture only. Paths and machine probes change; actual
        /// UpdateProcessLock, device gate, file fences and journaling do not.
        static func isolatedTests(providerLock: URL, deviceDirectory: URL,
                                  orphanCheck: @escaping () throws -> Void,
                                  linkReady: @escaping (String) throws -> Void,
                                  requirePhysicalInterface: @escaping (String, String) throws -> Void) -> Self {
            Self(providerLock: providerLock, deviceDirectory: deviceDirectory,
                orphanCheck: orphanCheck, linkReady: linkReady,
                requirePhysicalInterface: requirePhysicalInterface)
        }
    }

    private let lock = NSRecursiveLock()
    let environment: Environment
    private var provider: UpdateProcessLock?
    private var device: ClusterDeviceLease?
    private let providerFile: DistributedInstalledFiles.Identity
    private var matrixFile: DistributedInstalledFiles.Identity?
    private var matrixBytes: Data?
    private var matrixURL: URL?
    private var journalAttempted = false
    private var journalRecorded = false
    private var isRetired = false
    private var ownedDocument: URL?
    var retired: Bool { lock.withLock { isRetired } }
    var document: URL? { lock.withLock { ownedDocument } }

    init(environment: Environment, deadline: UInt64) throws {
        self.environment = environment
        // No ordinary-provider probe/borrowed-parent exception: keep this
        // actual UpdateProcessLock object until safe retirement.
        try ClusterConfigurationFiles.ensureDirectory(environment.providerLock.deletingLastPathComponent(),
            create: true, privateMode: false)
        let provider = try UpdateProcessLock.acquire(at: environment.providerLock, operation: "glm-finite-owner")
        let bytes = try ClusterConfigurationFiles.read(environment.providerLock, maximum: 4096, privateMode: true)
        providerFile = try DistributedInstalledFiles.verify(environment.providerLock,
            expectedSHA256: Self.hash(bytes), maximumBytes: 4096, deadline: deadline)
        try ClusterConfigurationFiles.ensureDirectory(environment.deviceDirectory, create: true, privateMode: true)
        let device = try ClusterDeviceLease(directoryURL: environment.deviceDirectory)
        self.provider = provider; self.device = device
        try requireHeld()
        try environment.orphanCheck()
    }

    func retainMatrix(completed: GLM5NextCalibrationInstalledQuote.Completed, deadline: UInt64) throws -> TransportSelection {
        lock.lock(); defer { lock.unlock() }
        guard matrixFile == nil, let path = completed.environment["JACCL_IBV_DEVICES"],
              let coordinator = completed.environment["JACCL_COORDINATOR"],
              !coordinator.isEmpty, coordinator.utf8.count <= 256 else {
            throw GLM5NextCalibrationDocument.invalid("Missing retained finite transport selection")
        }
        let pair = completed.pair, rank = completed.authorized.request.selection.rank
        let local = pair.record.link.localInterface, peer = pair.record.link.peerInterface
        guard ClusterLinkName.isInterface(local), ClusterLinkName.isInterface(peer) else {
            throw GLM5NextCalibrationDocument.invalid("Invalid paired physical interfaces")
        }
        // Same matrix convention as InstalledPlan.matrix: the off-diagonal
        // entry in each rank's row names that rank's physical RDMA device.
        // The pair's retained interfaces determine it; no chip/device-name search.
        let localDevice = "rdma_" + local, peerDevice = "rdma_" + peer
        let names = rank == 0 ? [localDevice, peerDevice] : [peerDevice, localDevice]
        let url = URL(fileURLWithPath: path)
        let bytes = try ClusterConfigurationFiles.read(url, maximum: 4096, privateMode: true)
        guard let rows = try JSONSerialization.jsonObject(with: bytes) as? [[Any]],
              rows.count == 2, rows.allSatisfy({ $0.count == 2 }),
              rows[0][0] is NSNull, rows[1][1] is NSNull,
              rows[0][1] as? String == names[0], rows[1][0] as? String == names[1] else {
            throw GLM5NextCalibrationDocument.invalid("Selected matrix differs from actual paired interfaces")
        }
        matrixFile = try DistributedInstalledFiles.verify(url, expectedSHA256: Self.hash(bytes),
            maximumBytes: 4096, deadline: deadline)
        matrixURL = url; matrixBytes = bytes
        try environment.requirePhysicalInterface(localDevice, local)
        try requireHeld()
        return TransportSelection(matrixSHA256: Self.hash(bytes), coordinator: coordinator,
            localInterface: local, device: localDevice)
    }

    func requireHeld() throws {
        lock.lock(); defer { lock.unlock() }
        try requireGatesHeld()
        if let matrixFile, let matrixURL, let matrixBytes {
            try matrixFile.requireUnchanged()
            guard try ClusterConfigurationFiles.read(matrixURL, maximum: 4096, privateMode: true) == matrixBytes else {
                throw GLM5NextCalibrationDocument.invalid("Selected matrix bytes changed")
            }
        }
    }

    private func requireGatesHeld(checkProviderMetadata: Bool = true) throws {
        guard !isRetired, let provider, let device else {
            throw GLM5NextCalibrationDocument.invalid("Finite exclusion was retired")
        }
        try provider.requireHeld()
        if checkProviderMetadata { try providerFile.requireUnchanged() }
        try device.requireHeld()
    }

    func write(_ authorization: GLM5NextCalibrationAuthorizer.Authorized) throws {
        lock.lock(); defer { lock.unlock() }
        try requireHeld()
        let directory = environment.deviceDirectory.appendingPathComponent("glm-calibration", isDirectory: true)
        try ClusterConfigurationFiles.ensureDirectory(directory, create: true, privateMode: true)
        ownedDocument = try GLM5NextCalibrationAuthorizer.write(authorization, directory: directory,
            now: Int64(Date().timeIntervalSince1970))
    }

    func record(binding: ClusterOwnerBinding, launchID: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try requireHeld()
        guard !journalAttempted, let device else { throw GLM5NextCalibrationDocument.invalid("Repeated finite journal") }
        journalAttempted = true // A partial write can NEVER be treated as an empty/no-launch journal.
        try device.record(clusterID: binding.route.clusterID, peerID: binding.route.ownerPeerID,
            rank: binding.rank, membershipEpoch: binding.route.membershipEpoch,
            leaseID: binding.route.leaseID, ownerIncarnation: binding.route.ownerIncarnation, nativeLaunchID: launchID)
        journalRecorded = true
        try requireHeld()
    }

    /// Caller must establish actual observed direct-child exit OR no-launch.
    /// Throws without releasing either lock on a partial/changed journal.
    func retireAfterExitOrNoLaunch() throws {
        lock.lock(); defer { lock.unlock() }
        guard !isRetired else { return }
        // Input mutation forbids launching, but does not revoke proof that no
        // child launched / the direct child exited. Still require the actual
        // canonical kernel gates and exact own journal before clearing it.
        try requireGatesHeld(checkProviderMetadata: false)
        if journalAttempted {
            guard journalRecorded, let device else { throw GLM5NextCalibrationDocument.invalid("Unresolved partial journal") }
            try device.resolve()
        }
        isRetired = true
        device = nil
        provider = nil
        // Only the document minted by this owner is eligible for cleanup.
        if let document = ownedDocument {
            do { try FileManager.default.removeItem(at: document); self.ownedDocument = nil } catch { }
        }
    }

    deinit {
        // Best effort second deletion only after safe retirement. Never delete
        // custody evidence just because a failed/unobserved owner was dropped.
        if isRetired, let document = ownedDocument { try? FileManager.default.removeItem(at: document) }
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
