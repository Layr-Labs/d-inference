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

    /// The verified worker, and an owner that is the verified file, are
    /// launched and read their input; an owner replaced after its check is
    /// refused before its open frame (which carries the credential) is written.
    static func verifiedLaunchesAndReplacedOwner(_ f: InstalledFixture, recorder: URL) throws {
        let bench = try LaunchImageBench(f, name: "launch-image-owner")
        defer { bench.attachment.cancel() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000

        // The native launch carries the check, and the unchanged worker passes it (run here in a mode that
        // waits, so the check cannot race its exit).
        let launch = try DistributedInstalledOwner.nativeLaunch(prepared: bench.prepared, binding: bench.binding,
            deadline: bench.deadline, startupDeadline: nil, attachment: bench.attachment, dataPlaneTrust: bench.trust,
            prefixSSDKey: nil, ownerEnvironment: [:])
        let check = try require(launch.verifyLaunched, "the native launch carries no check of the launched image")
        let genuine = Process()
        genuine.executableURL = bench.worker; genuine.arguments = ["--fixture-hang"]
        try genuine.run()
        defer { kill(genuine.processIdentifier, SIGKILL); genuine.waitUntilExit() }
        try check(genuine.processIdentifier)

        // The recorder, verified as itself, is launched and reads the credential.
        let own = bench.directory.appendingPathComponent("recorder")
        try FileManager.default.copyItem(at: recorder, to: own)
        let identity = try DistributedInstalledFiles.verify(own, expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: own)),
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        let accepted = try ClusterWorkerProcess(launch: .init(executable: own, arguments: [], environment: [:],
                initialInput: bench.trust, verifyLaunched: identity.launchVerifier()),
            expectedIdentity: bench.binding.identity, rank: bench.binding.rank, profile: bench.binding.profile,
            executionPlanSHA256: bench.binding.executionPlanSHA256, startupDeadline: bench.deadline, initialLeaseDeadline: bench.deadline)
        try accepted.launch()
        try require(bench.received(accepted) == bench.trust, "the verified child did not receive its input")
        try FileManager.default.removeItem(at: bench.recorded)

        // The owner: verified, then replaced before the endpoint launches it.
        let owner = bench.directory.appendingPathComponent("darkbloom")
        try FileManager.default.copyItem(at: f.owner, to: owner)
        let ownerIdentity = try DistributedInstalledFiles.verify(owner,
            expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: owner)),
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        try bench.replace(owner, with: recorder)
        try rejected {
            _ = try ClusterRemoteWorkerEndpoint(localOwner: ClusterLocalOwnerConfiguration(installedDarkbloom: owner),
                clusterID: bench.prepared.plan.configuration.clusterID, expectedIdentity: bench.binding.identity,
                profile: bench.binding.profile, rank: bench.binding.rank, executionPlanSHA256: bench.binding.executionPlanSHA256,
                lifetimeDeadlineUptimeNanoseconds: deadline, bootstrapRelay: nil, dataPlaneTrust: bench.trust,
                verifyLaunched: ownerIdentity.launchVerifier())
        }
        Thread.sleep(forTimeInterval: 0.3)
        try require(!FileManager.default.fileExists(atPath: bench.recorded.path),
            "an owner binary replaced after verification received its open frame")
        print("Installed launch image: cdhashes from the verified bytes match Code Signing Services; unsigned, truncated and replaced worker and owner binaries refused before their input; verified children launched (CPU)")
    }

    /// Two launches the real check must refuse although each child's image
    /// or file looks right when it is judged: a child that something resumed
    /// before its check ended (it has run code), and a child whose file was
    /// put back to the verified bytes while it waited, suspended, running other
    /// bytes (the file on disk is not what runs; the kernel's cdhash is).
    static func ranOrSwappedBeforeTheCheckIsRefused(_ f: InstalledFixture, recorder: URL) throws {
        let bench = try LaunchImageBench(f, name: "launch-image-timing")
        defer { bench.attachment.cancel() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        func worker(_ executable: URL, _ check: @escaping @Sendable (pid_t) throws -> Void) throws -> ClusterWorkerProcess {
            try ClusterWorkerProcess(launch: .init(executable: executable, arguments: [], environment: [:],
                    initialInput: bench.trust, verifyLaunched: check),
                expectedIdentity: bench.binding.identity, rank: bench.binding.rank, profile: bench.binding.profile,
                executionPlanSHA256: bench.binding.executionPlanSHA256, startupDeadline: bench.deadline, initialLeaseDeadline: bench.deadline)
        }

        // The recorder, verified as itself, but resumed by something else before its check.
        let own = bench.directory.appendingPathComponent("recorder")
        try FileManager.default.copyItem(at: recorder, to: own)
        let identity = try DistributedInstalledFiles.verify(own, expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: own)),
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        let ownCheck = try identity.launchVerifier()
        let resumed = try worker(own) { pid in
            _ = kill(pid, SIGCONT)
            Thread.sleep(forTimeInterval: 0.1)
            try ownCheck(pid)
        }
        var refused = false
        do { try resumed.launch() } catch { refused = true }
        try require(bench.received(resumed) == nil, "a child resumed before its check received the data-plane credential")
        try require(refused && resumed.termination == .launchFailed, "a child resumed before its check was launched")

        // The worker, verified, then replaced; while the replacement waits suspended the verified bytes are put
        // back at the path, so the file on disk matches again and only the running image differs.
        let verified = bench.directory.appendingPathComponent("verified-worker")
        try FileManager.default.copyItem(at: bench.worker, to: verified)
        let workerIdentity = try DistributedInstalledFiles.verify(bench.worker,
            expectedSHA256: ClusterConfigurationCodec.sha256(Data(contentsOf: bench.worker)),
            maximumBytes: 256 << 20, executable: true, deadline: deadline)
        let workerCheck = try workerIdentity.launchVerifier()
        try bench.replace(bench.worker, with: recorder)
        let path = bench.worker, staged = bench.directory.appendingPathComponent("staged-verified")
        try FileManager.default.copyItem(at: verified, to: staged)
        let swapped = try worker(path) { pid in
            guard rename(staged.path, path.path) == 0 else { throw CheckFailure(message: "could not put the verified worker back") }
            try workerCheck(pid)
        }
        refused = false
        do { try swapped.launch() } catch { refused = true }
        try require(bench.received(swapped) == nil, "a child whose file was put back while it waited received the data-plane credential")
        try require(refused && swapped.termination == .launchFailed, "a child running other bytes than its file was launched")
        print("Installed launch timing: a child resumed before its check and a child running other bytes than its restored file refused (CPU)")
    }
}
