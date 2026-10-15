import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
import DarkbloomClusterRemote
import MLXLMCommon
@testable import ProviderCore

final class RotationEndpoints: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [ClusterRemoteWorkerEndpoint] = []
    func append(_ endpoint: ClusterRemoteWorkerEndpoint) { lock.withLock { endpoints.append(endpoint) } }
    var values: [ClusterRemoteWorkerEndpoint] { lock.withLock { endpoints } }
}

struct RotationOwnedGeneration: Sendable {
    let session: DistributedInstalledSession
    let endpoints: RotationEndpoints
}

/// Actual owned children across generations reuse the SAME two canonical lease
/// inodes. No lease marker is cleared or replaced by this fixture.
final class RotationOwners: @unchecked Sendable {
    let fixture: InstalledFixture
    let prepared: DistributedInstalledPreparation
    let directories: [URL]
    let behavior: String
    let startupGate: RotationStartupGate?
    private let lock = NSLock()
    private var records: [RotationOwnedGeneration] = []
    private var leaseIdentities: [Int: LeaseIdentity] = [:]

    init(fixture: InstalledFixture, behavior: String = "normal", startupGate: RotationStartupGate? = nil) throws {
        self.fixture = fixture; prepared = try fixture.prepare()
        self.behavior = behavior; self.startupGate = startupGate
        directories = (0..<2).map { fixture.root.appendingPathComponent("canonical-rank-\($0)") }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    var snapshot: [RotationOwnedGeneration] { lock.withLock { records } }

    func first() throws -> DistributedInstalledSession {
        try rotationRequire(snapshot.isEmpty, "Initial owner was already prepared")
        return try appendGeneration()
    }

    func replacement() async throws -> any DistributedLocalServerSession {
        let previous = snapshot
        try rotationRequire(!previous.isEmpty && previous.count < 3, "Unexpected replacement count")
        try validateReleased(previous.last!)
        return try appendGeneration()
    }

    private func appendGeneration() throws -> DistributedInstalledSession {
        let index = snapshot.count
        let endpoints = RotationEndpoints()
        let session = try DistributedInstalledSession(prepared: prepared, endpointFactory: { [self] plan, id, rank, lifetime, relay in
            if index == 1, rank == 1, let startupGate { try startupGate.waitThenRefuse() }
            let ready = fixture.root.appendingPathComponent("ready-\(id.membershipEpoch.uuidString)-\(rank).json")
            let frame = ClusterWorkerEventFrame(membershipEpoch: id.membershipEpoch, sequence: 0, requestID: nil,
                event: .ready(.init(identity: id, rank: rank, profile: plan.capability.profile,
                    executionPlanSHA256: plan.partition.planSHA256, requestCapacityBytes: 1024)))
            try ClusterWorkerCodec.encode(frame).write(to: ready)
            let endpoint = try ClusterRemoteWorkerEndpoint(transport: .init(executable: fixture.owner,
                arguments: [fixture.worker.path, directories[rank].path, String(rank), behavior],
                environment: ["FIXTURE_READY_PATH": ready.path]), clusterID: plan.configuration.clusterID,
                expectedIdentity: id, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256,
                lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay)
            endpoints.append(endpoint)
            return endpoint
        })
        lock.withLock { records.append(.init(session: session, endpoints: endpoints)) }
        return session
    }

    func observeReady(_ record: RotationOwnedGeneration) throws {
        try rotationRequire(record.session.readiness() != nil && record.endpoints.values.count == 2,
                            "Generation lacks actual bilateral Ready")
        for rank in 0..<2 {
            let identity = try leaseIdentity(rank: rank, requireEmptyUnlocked: false)
            try lock.withLock {
                if let prior = leaseIdentities[rank] {
                    try rotationRequire(prior == identity, "Canonical lease inode changed across rotation")
                } else { leaseIdentities[rank] = identity }
            }
        }
    }

    func validateReleased(_ record: RotationOwnedGeneration) throws {
        try rotationRequire(record.session.canRotate && record.session.status == .released,
                            "Replacement attempted before installed release barrier")
        let endpoints = record.endpoints.values
        try rotationRequire(endpoints.count == 2 && endpoints.allSatisfy {
            $0.nativeCleanupObserved && $0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0)
        }, "Replacement preceded native cleanup, explicit owner ACK or clean transport termination")
        for rank in 0..<2 {
            let current = try leaseIdentity(rank: rank, requireEmptyUnlocked: true)
            try lock.withLock {
                try rotationRequire(leaseIdentities[rank] == current, "Released canonical lease identity changed")
            }
        }
    }

    func host(first: DistributedInstalledSession, discovery: RotationDiscovery) -> DistributedLocalServer {
        .init(session: first, config: .init(host: "127.0.0.1", port: 0),
              tokenizerLoader: { _ in TokenizerHandle(RotationTokenizer()) }, discovery: discovery.client,
              replacementSessionFactory: { try await self.replacement() })
    }

    struct LeaseIdentity: Equatable { let device: dev_t; let inode: ino_t }

    private func leaseIdentity(rank: Int, requireEmptyUnlocked: Bool) throws -> LeaseIdentity {
        let path = directories[rank].appendingPathComponent("native-device.lease").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        try rotationRequire(fd >= 0, "Cannot inspect fixture canonical lease")
        defer { close(fd) }
        var before = stat(), after = stat(), pathState = stat()
        try rotationRequire(fstat(fd, &before) == 0 && lstat(path, &pathState) == 0 &&
            before.st_dev == pathState.st_dev && before.st_ino == pathState.st_ino &&
            before.st_mode & S_IFMT == S_IFREG && before.st_mode & 0o777 == 0o600 &&
            before.st_nlink == 1 && before.st_uid == geteuid(), "Canonical lease metadata differs")
        if requireEmptyUnlocked {
            try rotationRequire(flock(fd, LOCK_EX | LOCK_NB) == 0, "Released owner still holds canonical lock")
            defer { flock(fd, LOCK_UN) }
            try rotationRequire(before.st_size == 0 && fstat(fd, &after) == 0 && after.st_size == 0 &&
                before.st_dev == after.st_dev && before.st_ino == after.st_ino,
                "Released canonical lease is not unchanged and empty")
        }
        return .init(device: before.st_dev, inode: before.st_ino)
    }
}
