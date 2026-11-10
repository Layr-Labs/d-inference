import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// `darkbloom cluster gpu-limit`: raise this Mac's GPU wired-memory limit
    /// for a GLM-5.3-Flash pair rank (`GLM5NextWiredLimit.pairRankRecommendation`),
    /// with the owner's one confirmation and then macOS's own administrator
    /// prompt (`GLM5NextGPULimitFlow`). `--undo` takes it back.
    struct GPULimit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "gpu-limit",
            abstract: "Let this Mac's GPU keep more memory resident so GLM-5.3-Flash runs on two Macs. Asks once; macOS asks an administrator.",
            discussion: """
                Raises the macOS GPU wired-memory limit (iogpu.wired_limit_mb) to this Mac's memory less 16 GiB \
                (a sixteenth from 512 GB), which macOS keeps, and the user wire limits to 95% of memory, now and \
                after every restart (a LaunchDaemon). Where the limits are already met, it installs the LaunchDaemon \
                if it is missing or differs, and changes nothing if it is in place. Only for Apple silicon Macs with \
                128 GB of memory or more; a limit the Mac does not report is never changed. Run it on each \
                Mac of the pair, in Terminal. `--undo` removes the LaunchDaemon and returns the GPU limit to the \
                macOS default; the wire limits return to theirs at the next restart.
                """)
        @Flag(help: "Return the GPU limit to the macOS default and remove the job that keeps it raised.")
        var undo = false

        mutating func run() async throws {
            guard let recommendation = GLM5NextWiredLimit.pairRankRecommendationForThisMac() else {
                let reason = GLM5NextWiredLimit.pairRankRefusalForThisMac() ?? "its chip or memory could not be read"
                print("This Mac's GPU memory limit is not raised: \(reason). `darkbloom cluster gpu-limit` runs on "
                    + "\(GLM5NextGPULimitEligibility.macs).")
                throw ExitCode(2)
            }
            let terminal = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
            let status = GLM5NextGPULimitFlow.run(undo: undo, recommendation: recommendation, runner: .live,
                confirm: terminal ? { question in
                    print(question, terminator: "")
                    fflush(stdout)
                    return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y"
                } : nil, say: { print($0) })
            if status != 0 { throw ExitCode(status) }
        }
    }
}
