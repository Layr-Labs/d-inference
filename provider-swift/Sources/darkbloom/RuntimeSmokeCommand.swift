import ArgumentParser
import ProviderCore

/// Package-real release gate. Hidden because it is invoked by CI against the
/// staged/extracted app, not by operators.
struct RuntimeSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime-smoke",
        abstract: "Internal: validate packaged runtime resources and kernels.",
        shouldDisplay: false)

    mutating func run() throws {
        try PackagedRuntimeSmoke.runPagedKernel()
        print("paged-kernel-runtime-smoke: ok")
    }
}
