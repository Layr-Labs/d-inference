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
            let qualification = try WorkerQualificationGate.admit(
                permitted: configuration.qualificationSwitchesPermitted,
                environment: ProcessInfo.processInfo.environment)
            let deadline = configuration.load.deadlineUptimeNanoseconds
            // Fixed before any native initialization. The signal handler neither
            // allocates nor claims cleanup: the parent must observe process exit.
            signal(SIGPIPE, SIG_IGN)
            signal(SIGALRM) { _ in Darwin._exit(124) }
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
            let runtime: any WorkerRuntime = try configuration.evidenceDirectory.map {
                try RecordingWorkerRuntime(configuration.load, bootstrap: configuration.bootstrap, evidenceDirectory: $0,
                    generationMode: configuration.generationMode, qualification: qualification)
            } ?? NativeWorkerRuntime(configuration.load, bootstrap: configuration.bootstrap,
                    generationMode: configuration.generationMode, qualification: qualification)
            startup?.disarm()
            try WorkerCoordinator(runtime: runtime, pipes: pipes).run()
            alarm(0)
            Darwin.exit(0)
        } catch {
            let message = Data(("darkbloom-cluster-worker: \(error)\n").utf8.prefix(4096))
            _ = message.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            Darwin.exit(1)
        }
    }
}
