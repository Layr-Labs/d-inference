import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote
@testable import InstalledContract

/// The installed worker is verified by its bytes and launched by its path. A
/// binary that replaces it after the last check is launched in its place;
/// it must be refused before its input carries the data-plane credential.
struct LaunchImageBench {
    let directory: URL, worker: URL, recorded: URL
    let prepared: DistributedInstalledPreparation, binding: ClusterOwnerBinding
    let attachment: ClusterOwnerBootstrapAttachment, trust: Data, deadline: UInt64

    /// A setup whose worker is a private copy of the probe, in a directory of its own.
    init(_ f: InstalledFixture, name: String) throws {
        directory = f.root.appendingPathComponent(name + "-bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        worker = directory.appendingPathComponent("darkbloom-cluster-worker")
        recorded = directory.appendingPathComponent("recorded-stdin")
        try FileManager.default.copyItem(at: f.probe, to: worker)
        let fixture = try InstalledFixture.make(root: f.root.appendingPathComponent(name), probe: worker, owner: f.owner, worker: f.worker)
        prepared = try fixture.prepare()
        let plan = prepared.plan
        binding = try plan.binding(epoch: UUID(), lease: UUID(), incarnation: UUID())
        deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        let starts = try DistributedInstalledNativeStart.starts(plan: plan, epoch: binding.identity.membershipEpoch)
        attachment = try ClusterOwnerBootstrapAttachment(profile: .nativeKeyPreludeMesh2,
            deadline: DispatchTime.now().uptimeNanoseconds + 10_000_000_000, nativeStart: starts[plan.configuration.localRank])
        trust = try ClusterDataPlaneLaunch.sessionCredentialLines(epoch: binding.identity.membershipEpoch)[plan.configuration.localRank]
    }

    /// Puts `replacement` at `file`'s name, as one rename.
    func replace(_ file: URL, with replacement: URL) throws {
        let staged = directory.appendingPathComponent("staged-" + UUID().uuidString)
        try FileManager.default.copyItem(at: replacement, to: staged)
        guard rename(staged.path, file.path) == 0 else { throw CheckFailure(message: "could not replace \(file.lastPathComponent)") }
    }

    /// The owner's native worker, exactly as `DistributedInstalledOwner.serve` builds it.
    func nativeWorker() throws -> ClusterWorkerProcess {
        let launch = try DistributedInstalledOwner.nativeLaunch(prepared: prepared, binding: binding, deadline: deadline,
            startupDeadline: nil, attachment: attachment, dataPlaneTrust: trust, prefixSSDKey: nil, ownerEnvironment: [:])
        return try ClusterWorkerProcess(launch: launch, expectedIdentity: binding.identity, rank: binding.rank,
            profile: binding.profile, executionPlanSHA256: binding.executionPlanSHA256,
            startupDeadline: deadline, initialLeaseDeadline: deadline)
    }

    /// Whatever the launched child read from its input, once it is gone.
    func received(_ worker: ClusterWorkerProcess) -> Data? {
        _ = worker.waitForExit(until: DispatchTime.now().uptimeNanoseconds + 5_000_000_000)
        worker.fence()
        return try? Data(contentsOf: recorded)
    }
}

extension InstalledSessionCheck {
    static func replacedWorkerIsRefused(_ f: InstalledFixture, recorder: URL) throws {
        let bench = try LaunchImageBench(f, name: "launch-image-worker")
        defer { bench.attachment.cancel() }
        try bench.prepared.requireUnchanged()
        try bench.replace(bench.worker, with: recorder)
        let worker = try bench.nativeWorker()
        var refused = false
        do { try worker.launch() } catch { refused = true }
        try require(bench.received(worker) == nil, "a worker binary replaced after verification received the data-plane credential")
        try require(refused && worker.termination == .launchFailed, "a worker binary replaced after verification was launched")
    }
}
