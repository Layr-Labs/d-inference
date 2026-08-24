#if DEBUG
import ArgumentParser
import Foundation
import ProviderCore

/// Hidden subprocess harness for cross-process single-instance lock tests.
/// Compiled only in debug builds and never exposed by release binaries.
struct RuntimeLockProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_runtime-lock-probe",
        abstract: "Internal process-lock test probe.",
        shouldDisplay: false
    )

    @Option(name: .long)
    var pidFile: String

    @Option(name: .long)
    var readyFile: String

    @Option(name: .long)
    var releaseFile: String

    @Option(name: .long)
    var terminationGrace: Double = 1

    mutating func run() async throws {
        let pidURL = URL(fileURLWithPath: pidFile)
        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidURL,
            terminationGracePeriod: terminationGrace
        )
        defer {
            ProcessLifecycle.releaseSingleInstanceLock(at: pidURL)
        }

        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            .write(to: URL(fileURLWithPath: readyFile), options: .atomic)

        let releaseURL = URL(fileURLWithPath: releaseFile)
        while !FileManager.default.fileExists(atPath: releaseURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
#endif
