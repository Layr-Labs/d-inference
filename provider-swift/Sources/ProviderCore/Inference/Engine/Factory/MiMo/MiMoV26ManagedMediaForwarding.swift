import Foundation

/// Native-media event fidelity only. The existing lease owns and joins both
/// this forwarder and its bridge cancellation; no new unowned collector task.
enum MiMoV26ManagedMediaForwarding {
    static func handoff(
        upstream: AsyncStream<GenerationEvent>, lease: NativeLocalConsumerLease,
        release: OneShotRelease, cancel: @escaping @Sendable () async -> Void
    ) throws -> (stream: AsyncStream<GenerationEvent>, handoff: NativeLocalConsumerLease.ForwardingHandoff) {
        let (events, continuation) = AsyncStream<GenerationEvent>.makeStream()
        let handoff = try lease.makeForwardingHandoff(cancelForwardingTask: false, cancel: {
            await cancel()
            await release.fire()
        }, operation: {
            var observedTerminal = false
            // This registered task is not directly cancelled. Its actual
            // upstream bridge owns the terminal, including a sticky native fault.
            for await event in upstream {
                switch event {
                case .chunk:
                    if lease.snapshot().phase == .active { continuation.yield(event) }
                case .info, .error, .terminal:
                    observedTerminal = true
                    continuation.yield(event)
                }
            }
            if !observedTerminal {
                continuation.yield(.error("native media stream closed without a terminal event"))
            }
            continuation.finish()
            await release.fire()
        })
        continuation.onTermination = { _ in handoff.terminate() }
        return (events, handoff)
    }
}
