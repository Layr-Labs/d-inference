import DarkbloomClusterProcess
import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Darwin
import Foundation

@main enum WorkerMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "--glm-calibration-quote" {
                try GLM5NextCalibrationQuoteCommand.run(arguments: Array(arguments.dropFirst()))
                Darwin.exit(0)
            }
            if arguments.first == "--glm-calibrate" {
                try GLM5NextCalibrationCommand.run(arguments: Array(arguments.dropFirst()))
                // Observations never prove retirement or permit process reuse.
                ProcessForcedExit.finish(status: 0, reason: "glm-calibration-process-exit-only")
            }
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
            // Before anything native: tensor parallel's collective wait (MLX reads it once).
            if let line = WorkerCollectiveSynchronization.apply(mode: configuration.generationMode,
                                                                environment: ProcessInfo.processInfo.environment) {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            // Before anything native: tensor parallel's command-buffer budget (read once too).
            if let line = WorkerCommandBufferBudget.apply(mode: configuration.generationMode,
                                                          environment: ProcessInfo.processInfo.environment) {
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            // Before anything native: a qualification switch in the environment
            // of a worker that was not started with the test flag ends it here.
            let environment = ProcessInfo.processInfo.environment
            // The prefix-SSD key comes only on the input: a launcher that put it
            // (or its file) in the environment is refused here, by name.
            try WorkerPrefixSSDKey.refuseEnvironmentKey(environment)
            let qualification = try WorkerQualificationGate.admit(
                permitted: configuration.qualificationSwitchesPermitted, environment: environment)
            let stageResidency = try qualification.stageResidencyRequested(environment: environment)
            let deadline = configuration.load.deadlineUptimeNanoseconds
            // Fixed before any native initialization and before any other
            // thread exists. Every forced end of this process from here on goes
            // through one exit (`ProcessForcedExit`): MLX's wired limit to zero
            // and its cache returned first, behind a 20 s dead-man. SIGTERM and
            // the lease alarm are routed to it; SIGINT and SIGHUP too, unless
            // the launcher started this worker with them ignored.
            signal(SIGPIPE, SIG_IGN)
            ProcessNativeMemoryRelease.installForForcedExit()
            try ProcessForcedExit.routeTerminationSignals()
            // The rank-side force-cancel hook (SIGUSR1): routed now, before
            // any other thread; what it does is installed with the coordinator.
            try WorkerForceCancelSignal.route()
            let beforeAlarm = DispatchTime.now().uptimeNanoseconds
            guard deadline > beforeAlarm else { throw WorkerFailure.invalid("Worker startup exhausted its deadline") }
            let remaining = deadline - beforeAlarm
            guard remaining <= ClusterWorkerLease.maximumNanoseconds else {
                throw WorkerFailure.invalid("Worker first lease grant exceeds its bound")
            }
            alarm(UInt32((remaining + 999_999_999) / 1_000_000_000) + 1)
            // The rank lease (S03), armed before any weights load: this thread
            // ends the process at the lease's deadline unless the owner renews
            // it. The alarm did not end a rank spinning in the RDMA completion
            // poll on real hardware; this thread is the last resort relied on.
            try ProcessDeadline.arm(lease: configuration.lease, status: 124)
            // Loading and the native bootstrap cannot be interrupted from
            // inside. An owner that names a startup deadline gets a worker
            // that is gone by then unless it became ready.
            let startup = try configuration.startupDeadlineUptimeNanoseconds.map {
                try WorkerStartupDeadline.arm(uptimeNanoseconds: $0)
            }
            // The data-plane credential, before the control reader takes the pipe.
            let dataPlane = configuration.dataPlaneEncrypted
                ? try WorkerDataPlaneTrust.read(descriptor: STDIN_FILENO,
                    until: min(configuration.lease.uptimeNanoseconds, configuration.startupDeadlineUptimeNanoseconds ?? UInt64.max),
                    epoch: configuration.load.identity.membershipEpoch, rank: configuration.load.rank)
                : nil
            // Then this rank's prefix-SSD key, when the owner announced it.
            let prefixSSDKey = configuration.prefixSSDKeyOnInput
                ? try WorkerPrefixSSDKey.read(descriptor: STDIN_FILENO,
                    until: min(configuration.lease.uptimeNanoseconds, configuration.startupDeadlineUptimeNanoseconds ?? UInt64.max),
                    epoch: configuration.load.identity.membershipEpoch, rank: configuration.load.rank)
                : nil
            let pipes = try WorkerPipes(input: STDIN_FILENO, output: STDOUT_FILENO, lease: configuration.lease)
            try pipes.check()
            // The control reader runs from here, through the load, so the
            // owner's renewals keep the lease alive while weights load. Each
            // renewal also moves the alarm, the second of the two last resorts.
            let coordinator = WorkerCoordinator(pipes: pipes, membershipEpoch: configuration.load.identity.membershipEpoch,
                keepWarm: configuration.keepWarm, exitHooks: .forcedExit,
                renewal: { ttl in alarm(UInt32((ttl + 999_999_999) / 1_000_000_000) + 1) })
            coordinator.startReading()
            WorkerForceCancelSignal.install { reason in coordinator.forceCancel(reason: reason) }
            // Nothing is loaded over memory a dead process left wired.
            try ClusterOrphanWiredGuard.check(role: "worker-rank-\(configuration.load.rank)")
            // The registered model's own adapter executes it: GPT-OSS has its
            // own runtime (with its own recording entry); the dense and MiMo
            // families share the native wrapper, and only the dense one records.
            // The owner's attachment (S07): the native key prelude, then the
            // exchange that creates the JACCL group through both owners.
            let attachment = try configuration.bootstrap?.attach(epoch: configuration.load.identity.membershipEpoch,
                rank: configuration.load.rank)
            let runtime: any WorkerRuntime
            if let document = configuration.glmQualificationDocument {
                guard let dataPlane else { throw WorkerFailure.invalid("GLM qualification requires authenticated data plane") }
                runtime = try GLM5NextWorkerRuntime(configuration: configuration, document: document,
                    credential: dataPlane, attachment: attachment)
            } else if configuration.family == .gptoss {
                runtime = try GPTOSSWorkerRuntime(configuration.load, attachment: attachment,
                    evidenceDirectory: configuration.evidenceDirectory,
                    generationMode: configuration.generationMode, qualification: qualification, dataPlane: dataPlane)
            } else {
                guard let family = configuration.family else { throw WorkerFailure.invalid("Missing registered model family") }
                guard configuration.family == .qwenDense || configuration.evidenceDirectory == nil else {
                    throw WorkerFailure.invalid("Only the dense adapter has a recording runtime; run this model without --evidence-directory")
                }
                runtime = try configuration.evidenceDirectory.map {
                    try RecordingWorkerRuntime(configuration.load, attachment: attachment, evidenceDirectory: $0,
                        generationMode: configuration.generationMode, speculativeTerms: configuration.speculativeTerms,
                        qualification: qualification, dataPlane: dataPlane, prefixSSDKey: prefixSSDKey)
                } ?? NativeWorkerRuntime(configuration.load, family: family, attachment: attachment,
                        generationMode: configuration.generationMode, speculativeTerms: configuration.speculativeTerms,
                        qualification: qualification, dataPlane: dataPlane, prefixSSDKey: prefixSSDKey,
                        tensorShares: configuration.tensorShares)
            }
            // Qualification only: a standing wired limit for the loaded stage.
            // Every exit below resets it to zero.
            let residency: ProcessStageResidency? = stageResidency
                ? try WorkerStageResidency.hold(runtime: runtime, rank: configuration.load.rank) : nil
            startup?.disarm()
            try coordinator.run(runtime: runtime)
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
