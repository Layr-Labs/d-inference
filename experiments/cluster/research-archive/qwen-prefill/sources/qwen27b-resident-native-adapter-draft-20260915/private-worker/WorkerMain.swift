import Darwin
import Foundation
@_spi(Benchmark) import DarkbloomClusterRuntime

@main enum WorkerMain {
    static func main() {
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["clock"] {
                print(DispatchTime.now().uptimeNanoseconds)
                Darwin.exit(0)
            }
            let argumentsOnly = arguments.first == "check-arguments"
            if argumentsOnly { arguments.removeFirst() }
            let now = DispatchTime.now().uptimeNanoseconds
            let configuration = try WorkerConfiguration(arguments: arguments, now: now,
                nativeValidation: .qwen38TwentySevenB)
            guard configuration.bootstrap != nil else {
                throw WorkerFailure.invalid("Native validation worker requires authenticated owner bootstrap")
            }
            if argumentsOnly { Darwin.exit(0) }
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
            let pipes = try WorkerPipes(input: STDIN_FILENO, output: STDOUT_FILENO, deadline: deadline)
            try pipes.check()
            let runtime = try NativeWorkerRuntime(configuration.load, bootstrap: configuration.bootstrap)
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
