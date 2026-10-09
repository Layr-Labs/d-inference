import Foundation
import Darwin
import DarkbloomClusterProtocol
import DarkbloomClusterProcess
@testable import DarkbloomClusterRemote
@testable import InstalledContract

/// Stands in for `darkbloom start --local --distributed` in the console checks.
/// It runs the real installed session over the fabricated owner and worker
/// children the installed-session checks use: real owner service, real worker
/// protocol, no model, no GPU, no network. Like the real command it prints as
/// it goes, writes the leader's status for an observer, and stops the session
/// cooperatively when interrupted.
///
/// usage: ConsoleSessionStandIn <probe> <owner> <worker> <fixture-root> <status-file>
@main enum ConsoleSessionStandIn {
    static let nonce = "00000000-0000-4000-8000-000000000001"

    static func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// Interrupts are latched from the first moment, as the real command's
    /// are. The handler runs on a dispatch queue, so it is built outside the
    /// main actor that `main` belongs to.
    nonisolated(unsafe) static var interruptSource: DispatchSourceSignal?

    nonisolated static func latchInterrupt() -> DispatchSemaphore {
        signal(SIGINT, SIG_IGN)
        let interrupted = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler(handler: DispatchWorkItem { interrupted.signal() })
        source.resume()
        interruptSource = source
        return interrupted
    }

    static func main() async throws {
        signal(SIGALRM) { _ in Darwin._exit(124) }; alarm(60)
        let arguments = CommandLine.arguments
        guard arguments.count == 6 else { exit(64) }
        let interrupted = latchInterrupt()

        let root = URL(fileURLWithPath: arguments[4]), statusFile = URL(fileURLWithPath: arguments[5])
        let owner = URL(fileURLWithPath: arguments[2]), worker = URL(fileURLWithPath: arguments[3])
        let fixture = try InstalledFixture.make(root: root, probe: URL(fileURLWithPath: arguments[1]), owner: owner, worker: worker,
            lifetimeSeconds: 30)
        let prepared = try fixture.prepare()
        let base = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let session = try DistributedInstalledSession(prepared: prepared, endpointFactory: { plan, identity, rank, lifetime, relay in
            let directory = base.appendingPathComponent("rank-\(rank)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let ready = base.appendingPathComponent("ready-\(rank).json")
            let frame = ClusterWorkerEventFrame(membershipEpoch: identity.membershipEpoch, sequence: 0, requestID: nil,
                event: .ready(.init(identity: identity, rank: rank, profile: plan.capability.profile,
                    executionPlanSHA256: plan.partition.planSHA256, requestCapacityBytes: 1024 * (rank + 1))))
            try ClusterWorkerCodec.encode(frame).write(to: ready)
            return try ClusterRemoteWorkerEndpoint(transport: .init(executable: owner,
                arguments: [worker.path, directory.path, String(rank), "normal"], environment: ["FIXTURE_READY_PATH": ready.path]),
                clusterID: plan.configuration.clusterID, expectedIdentity: identity, profile: plan.capability.profile, rank: rank,
                executionPlanSHA256: plan.partition.planSHA256, lifetimeDeadlineUptimeNanoseconds: lifetime, bootstrapRelay: relay)
        })
        // The saved setup's binding, as the session itself reports it.
        let binding = session.diagnosticObservation.binding

        /// The leader's status as the local server reports it, from the session's own observation.
        func publish(host: String) throws {
            let observation = session.diagnosticObservation
            let ready = host == "serving" && observation.ready
            let admission = observation.admission
            let status = ClusterLiveStatus(schema: ClusterLiveStatus.schemaName, nonce: nonce, binding: binding,
                authenticationConfigured: false, hostPhase: host, session: observation, boundPort: 8000, acquisitions: 0, failed: false,
                ready: ready,
                admissionAvailable: ready && admission?.valid == true && admission?.activeRequest == false
                    && admission?.draining == false && (admission?.remainingRequests ?? 0) > 0,
                quarantined: host == "quarantined" || observation.phase == "quarantined")
            let temporary = statusFile.appendingPathExtension("tmp")
            try ClusterStatusCodec.encode(status).write(to: temporary)
            guard rename(temporary.path, statusFile.path) == 0 else { throw ClusterConfigurationError.invalid("status publish failed") }
        }

        say("stand-in session for \(session.model.publicModelID)")
        try publish(host: "starting")
        try await session.start()
        try publish(host: "serving")
        say("both ranks ready; listening is not part of this stand-in")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { interrupted.wait(); continuation.resume() }
        }
        say("interrupt received; stopping")
        try publish(host: "stopping")
        let result = await session.stop(until: DispatchTime.now().uptimeNanoseconds + 15_000_000_000)
        try publish(host: "stopped")
        say("session \(result.rawValue)")
        exit(result == .released ? 0 : 3)
    }
}
