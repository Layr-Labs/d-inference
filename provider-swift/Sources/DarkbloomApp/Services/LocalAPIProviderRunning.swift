import Foundation
import ProviderCoreFoundation

/// A foreground local server has no success/launch timeout. The call remains
/// alive for the owned child's lifetime; readiness is independently observed.
protocol LocalAPIProviderRunning: Sendable {
    func run(
        arguments: [String],
        onLaunch: @escaping @Sendable (ProcessIdentity) -> Void
    ) async throws -> ProviderCLIResult
}

/// Shares CLI discovery and typed result/error shapes with the normal provider
/// runner, but never gives a healthy foreground server a command-exit deadline.
struct ProcessLocalAPIProviderRunner: LocalAPIProviderRunning {
    let locator: any DarkbloomCLILocating
    let terminationGrace: Duration

    init(
        locator: any DarkbloomCLILocating = SystemDarkbloomCLILocator(),
        terminationGrace: Duration = .seconds(2)
    ) {
        self.locator = locator
        self.terminationGrace = terminationGrace
    }

    func run(
        arguments: [String],
        onLaunch: @escaping @Sendable (ProcessIdentity) -> Void
    ) async throws -> ProviderCLIResult {
        try Task.checkCancellation()
        guard arguments.count == 5,
              arguments == LocalAPIStartCommand.arguments(modelID: arguments[3]),
              !arguments[3].isEmpty, !arguments[3].hasPrefix("-"), !arguments[3].contains("\0")
        else { throw LocalAPIStartError.launchFailed("The local-start command was invalid.") }
        guard let executable = locator.locate() else { throw ProviderCLIError.cliNotFound }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let tail = LocalAPIProcessStderr()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            tail.append(handle.availableData)
        }
        let child = LocalAPIOwnedProcess(process: process, terminationGrace: terminationGrace)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    process.terminationHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    // Never wait for EOF from inherited descendant pipe handles.
                    // The already-collected tail is bounded; exit status remains
                    // authoritative even if the final stderr callback raced exit.
                    child.finish {
                        if child.wasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            let result = ProviderCLIResult(exitStatus: process.terminationStatus, stderrTail: tail.text)
                            if result.exitStatus == 0 {
                                continuation.resume(returning: result)
                            } else {
                                continuation.resume(throwing: ProviderCLIError.exited(result.exitStatus, message: result.failureMessage))
                            }
                        }
                    }
                }
                do {
                    // Cancellation and process.run are serialized. Capture the
                    // kernel identity before publishing ownership/readiness.
                    if let identity = try child.launch() { onLaunch(identity) }
                } catch {
                    stderr.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    child.finish { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            child.cancel()
        }
    }
}

private final class LocalAPIProcessStderr: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > 4096 { data = Data(data.suffix(4096)) }
        }
    }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
