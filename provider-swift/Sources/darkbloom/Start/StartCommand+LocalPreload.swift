import Foundation
import ProviderCore

/// A startup signal must wake the CLI even if a model load does not cooperate
/// with task cancellation. The serve process can then exit without opening a
/// listener or publishing local discovery for a stopped startup.
final class LocalStartupPreloadBarrier: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case completed(StartupPreloader.Summary)
        case interrupted
    }

    private let stream: AsyncStream<Outcome>
    private let continuation: AsyncStream<Outcome>.Continuation

    init() {
        let pair = AsyncStream<Outcome>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func complete(_ summary: StartupPreloader.Summary) {
        continuation.yield(.completed(summary))
        continuation.finish()
    }

    func interrupt() {
        continuation.yield(.interrupted)
        continuation.finish()
    }

    func wait() async -> Outcome {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .interrupted
    }
}

extension Start {
    /// Standalone preload runs before binding HTTP. Install a temporary signal
    /// handler first so Ctrl-C can stop startup even if one load is wedged.
    internal func runLocalStartupPreload(
        server: StandaloneServer, config: ProviderConfig
    ) async -> Bool {
        guard config.backend.startupPreload else { return true }
        let barrier = LocalStartupPreloadBarrier()
        let preload = Task {
            let summary = await server.preloadSelectedModels(
                configuredModelIDs: config.backend.preloadModels)
            barrier.complete(summary)
        }
        await ProviderTermination.shared.install {
            preload.cancel()
            barrier.interrupt()
            return true
        }
        switch await barrier.wait() {
        case .interrupted:
            return false
        case .completed(let summary):
            guard !(await ProviderTermination.shared.terminationRequested) else {
                return false
            }
            print("Startup preload: \(summary.loaded.count) model(s) loaded")
            return true
        }
    }
}
