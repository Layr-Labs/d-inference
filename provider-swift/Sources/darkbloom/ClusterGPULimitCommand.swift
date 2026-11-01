import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// `darkbloom cluster gpu-limit`: raise this Mac's GPU wired-memory limit
    /// for a GLM-5.3-Flash pair rank (`GLM5NextWiredLimit.pairRankRecommendation`),
    /// with the owner's one confirmation and then macOS's own administrator
    /// prompt (`GLM5NextWiredLimitApproval`). `--undo` takes it back.
    struct GPULimit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "gpu-limit",
            abstract: "Let this Mac's GPU keep more memory resident so GLM-5.3-Flash runs on two 128 GB Macs. Asks once; macOS asks an administrator.",
            discussion: """
                Raises the macOS GPU wired-memory limit (iogpu.wired_limit_mb) to this Mac's memory less 16 GiB, \
                which macOS keeps, and the user wire limits to 95% of memory, now and after every restart (a \
                LaunchDaemon). Only for M5 Macs of 128 or 256 GB. Run it on each Mac of the pair, in Terminal. \
                `--undo` removes the LaunchDaemon and returns the GPU limit to the macOS default; the wire limits \
                return to theirs at the next restart.
                """)
        @Flag(help: "Return the GPU limit to the macOS default and remove the job that keeps it raised.")
        var undo = false

        mutating func run() async throws {
            let limits = GLM5NextWiredLimit.Limits.live()
            guard let recommendation = GLM5NextWiredLimit.pairRankRecommendationForThisMac() else {
                print("No GPU memory limit is recommended for this Mac: only M5 Macs with 128 or 256 GB serve as a GLM-5.3-Flash pair rank this way.")
                throw ExitCode(2)
            }
            let gib = { (bytes: UInt64) in String(format: "%.2f GiB", Double(bytes) / Double(1 << 30)) }
            print("This Mac's GPU keeps \(gib(limits.gpuLimitBytes)) resident now"
                + (limits.gpuWiredLimitMB.map { $0 > 0 ? " (iogpu.wired_limit_mb=\($0))." : " (the macOS default)." } ?? "."))
            if !undo, recommendation.isMet(by: limits) {
                print("It already meets the recommendation for this \(recommendation.memoryGiB) GB Mac (\(gib(recommendation.gpuWiredLimitBytes))). Nothing to change.")
                return
            }
            guard let request = GLM5NextWiredLimitRequest(undo ? .remove : .raise(recommendation)) else {
                throw ValidationError("The recommendation is not one this command applies.")
            }
            print(undo ? "This returns the GPU limit to the macOS default and removes the job that keeps it raised."
                : "This lets the GPU keep up to \(gib(recommendation.gpuWiredLimitBytes)) resident (macOS keeps 16 GiB), now and after every restart.")
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                print("No terminal to confirm in. An administrator can run these instead:")
                for line in request.manualCommands { print("  " + line) }
                throw ExitCode(2)
            }
            print("\(undo ? "Undo it" : "Raise it") now? macOS will ask an administrator to approve. [y/N] ", terminator: "")
            fflush(stdout)
            guard readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y" else {
                print("Nothing was changed.")
                return
            }
            switch GLM5NextWiredLimitApproval.request(request) {
            case .applied:
                let now = GLM5NextWiredLimit.Limits.live()
                print("Done. This Mac's GPU now keeps \(gib(now.gpuLimitBytes)) resident. Run `darkbloom cluster` again so both "
                    + "Macs plan and load with it.")
            case .declined:
                print("Nothing was changed: the approval was cancelled.")
                throw ExitCode(1)
            case .unavailable:
                print("macOS could not show the approval here. An administrator can run these instead:")
                for line in request.manualCommands { print("  " + line) }
                throw ExitCode(1)
            case .commandFailed:
                print("macOS ran the change and a step failed; run `darkbloom cluster gpu-limit` again to see what is in place.")
                throw ExitCode(1)
            }
        }
    }
}
