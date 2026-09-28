import Darwin
@_spi(OwnerService) import DarkbloomClusterProcess
@_spi(Benchmark) import DarkbloomClusterRuntime
import Foundation

@main enum SelectedLoadMain {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments == ["clock"] {
                // Same Swift clock as every native deadline check. Python's
                // process-relative monotonic origin is not interchangeable.
                print(DispatchTime.now().uptimeNanoseconds)
                return
            }
            let value = try SelectedLoadInput(arguments: arguments,
                now: DispatchTime.now().uptimeNanoseconds)
            let configuration = value.worker.load
            if value.mode == .checkArguments {
                // Pure parsing only: no metadata/model read, exclusion, MLX
                // operation, collective or payload-load invocation.
                print("{\"argumentsAccepted\":true,\"modelLoaded\":false}")
                return
            }
            let deadline = configuration.deadlineUptimeNanoseconds
            signal(SIGPIPE, SIG_IGN)
            signal(SIGALRM) { _ in Darwin._exit(124) }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline, deadline - now <= 300_000_000_000 else {
                throw WorkerFailure.invalid("Loading-check lifetime exhausted")
            }
            alarm(UInt32((deadline - now + 999_999_999) / 1_000_000_000))
            let output = try SelectedLoadOutput(descriptor: STDOUT_FILENO, deadline: deadline)
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".darkbloom/cluster-device", isDirectory: true)
            let exclusion = try ClusterDeviceExclusion(directoryURL: directory)
            let journal = try JSONSerialization.data(withJSONObject: [
                "schema": "private_mtp_selected_load_owner_v1", "processID": getpid(),
                "runID": configuration.identity.membershipEpoch.uuidString.lowercased(),
                "deadlineUptimeNanoseconds": deadline,
            ], options: [.sortedKeys])
            try exclusion.recordNativeOwnership(journal)
            let report = try QwenResidentMTPLoadCheck.run(configuration: configuration,
                onAdmitted: { try output.write($0) })
            // The SPI has already retired native values and encoded only CPU
            // evidence. A failed/partial load never reaches journal resolution;
            // the parent must fence it and explicitly recover sticky ownership.
            try exclusion.resolveNativeOwnership()
            try output.write(report)
            withExtendedLifetime(exclusion) {}
            alarm(0)
        } catch {
            let message = Data(("mtp-selected-load-check: \(error)\n").utf8.prefix(4096))
            _ = message.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            Darwin.exit(1)
        }
    }
}
