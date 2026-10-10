import DarkbloomClusterProcess
import DarkbloomClusterRuntime
import Darwin
import Foundation

@main enum WorkerMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--describe-runtime" {
                try WorkerCapabilityCommand.run(arguments: arguments)
                Darwin.exit(0)
            }
            if arguments == ["--uptime-nanoseconds"] {
                // The clock every worker deadline is expressed in, for a launcher
                // on another Mac that must translate a remaining duration.
                print(DispatchTime.now().uptimeNanoseconds)
                Darwin.exit(0)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            let configuration = try WorkerConfiguration(arguments: arguments, now: now)
            // Before anything native: a qualification switch in the environment
            // of a worker that was not started with the test flag ends it here.
            let environment = ProcessInfo.processInfo.environment
            let qualification = try WorkerQualificationGate.admit(
                permitted: configuration.qualificationSwitchesPermitted, environment: environment)
            let stageResidency = try qualification.stageResidencyRequested(environment: environment)
            let deadline = configuration.load.deadlineUptimeNanoseconds
            // Fixed before any native initialization and before any other
            // thread exists. Every forced end of this process from here on goes
            // through one exit (`ProcessForcedExit`): MLX's wired limit to zero
            // and its cache returned first, behind a 20 s dead-man. SIGTERM and
            // the lifetime alarm are routed to it; SIGINT and SIGHUP too, unless
            // the launcher started this worker with them ignored.
            signal(SIGPIPE, SIG_IGN)
            ProcessNativeMemoryRelease.installForForcedExit()
            try ProcessForcedExit.routeTerminationSignals()
            let beforeAlarm = DispatchTime.now().uptimeNanoseconds
            guard deadline > beforeAlarm else { throw WorkerFailure.invalid("Worker startup exhausted its deadline") }
            let remaining = deadline - beforeAlarm
            guard remaining <= 300_000_000_000 else { throw WorkerFailure.invalid("Worker startup lifetime exceeds its bound") }
            alarm(UInt32((remaining + 999_999_999) / 1_000_000_000))
            // The alarm did not end a rank spinning in the RDMA completion poll
            // on real hardware; this thread is the last resort that is relied on.
            try ProcessDeadline.arm(uptimeNanoseconds: deadline, status: 124)
            // Loading and the native bootstrap cannot be interrupted from
            // inside. An owner that names a startup deadline gets a worker
            // that is gone by then unless it became ready.
            let startup = try configuration.startupDeadlineUptimeNanoseconds.map {
                try WorkerStartupDeadline.arm(uptimeNanoseconds: $0)
            }
            let pipes = try WorkerPipes(input: STDIN_FILENO, output: STDOUT_FILENO, deadline: deadline)
            try pipes.check()
            // Nothing is loaded over memory a dead process left wired.
            try ClusterOrphanWiredGuard.check(role: "worker-rank-\(configuration.load.rank)")
            let runtime: any WorkerRuntime = try configuration.evidenceDirectory.map {
                try RecordingWorkerRuntime(configuration.load, bootstrap: configuration.bootstrap, evidenceDirectory: $0,
                    generationMode: configuration.generationMode, qualification: qualification)
            } ?? NativeWorkerRuntime(configuration.load, bootstrap: configuration.bootstrap,
                    generationMode: configuration.generationMode, qualification: qualification)
            // Qualification only: a standing wired limit for the loaded stage.
            // Every exit below resets it to zero.
            let residency: ProcessStageResidency? = stageResidency
                ? try WorkerStageResidency.hold(runtime: runtime, rank: configuration.load.rank) : nil
            startup?.disarm()
            try WorkerCoordinator(runtime: runtime, pipes: pipes, exitHooks: .forcedExit).run()
            alarm(0)
            withExtendedLifetime(residency) {}
            ProcessForcedExit.finish(status: 0, reason: "shutdown-complete")
        } catch {
            let message = Data(("darkbloom-cluster-worker: \(error)\n").utf8.prefix(4096))
            _ = message.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            ProcessForcedExit.finish(status: 1, reason: "worker-error")
        }
    }
}

/// The stage residency a qualification run asked for, logged for the report.
enum WorkerStageResidency {
    static func hold(runtime: any WorkerRuntime, rank: Int) throws -> ProcessStageResidency {
        let capacity = runtime.readiness?.requestCapacityBytes ?? 0
        let stage = ProcessStageResidency.activeBytes
        let value = try ProcessStageResidency(bytes: stage + capacity)
        let r = value.receipt
        FileHandle.standardError.write(Data(("darkbloom-stage-residency-v1 rank=\(rank) policy=\(r.policy)"
            + " stage_active=\(stage) request_capacity=\(capacity) requested=\(r.requestedBytes) ceiling=\(r.ceilingBytes)"
            + " applied=\(r.appliedBytes) previous=\(r.previousBytes) recommended=\(r.recommendedWorkingSetBytes)\n").utf8))
        return value
    }
}
