import Foundation
import MLXLMCommon

/// The error a `ScriptedBenchmarkEngine` throws from `submit`.
struct ScriptedBenchmarkRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// What a `ScriptedBenchmarkEngine` does with one submitted request.
enum ScriptedBenchmarkReply: Sendable {
    /// Emit the events in order, each one after `gap`, then end the stream.
    case events([CBv2Event], gap: Duration)
    /// Emit the events and keep the stream open until `cancel` or `shutdown`.
    case open([CBv2Event])
    /// Throw `ScriptedBenchmarkRefusal` from `submit`.
    case refuse(String)
}

/// A model-free `CBv2Engine` for benchmark harness tests. A script decides
/// the events for each request. The engine records every request, every
/// cancel, and every shutdown, and returns packed-prefill counters from a
/// queue so a probe can see a "before" and an "after" value.
final class ScriptedBenchmarkEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private let script: @Sendable (CBv2Request) -> ScriptedBenchmarkReply
    private let cancelReason: CBv2FinishReason?
    private let snapshot: CBv2CapacitySnapshot
    private var packedReads: [CBv2PackedPrefillActivity]
    private var openStreams: [CBv2RequestID: AsyncStream<CBv2Event>.Continuation] = [:]
    private var submitHook: (@Sendable (CBv2Request) -> Void)?
    private var _requests: [CBv2Request] = []
    private var _cancelled: [CBv2RequestID] = []
    private var _shutdownCalls = 0

    /// `cancelReason` is the terminal that `cancel` sends to an open stream.
    /// Nil means `cancel` sends nothing and the stream stays open.
    init(
        packedActivity: [CBv2PackedPrefillActivity] = [],
        cancelReason: CBv2FinishReason? = .cancelled,
        capacity: CBv2CapacitySnapshot = CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 1 << 20, kvBytesReserved: 0, activeTokens: 0),
        script: @escaping @Sendable (CBv2Request) -> ScriptedBenchmarkReply
    ) {
        self.packedReads = packedActivity
        self.cancelReason = cancelReason
        self.snapshot = capacity
        self.script = script
    }

    var requests: [CBv2Request] { lock.withLock { _requests } }
    var cancelledIDs: [CBv2RequestID] { lock.withLock { _cancelled } }
    var shutdownCalls: Int { lock.withLock { _shutdownCalls } }

    /// Runs after each accepted submission, outside the engine lock.
    func onSubmit(_ hook: @escaping @Sendable (CBv2Request) -> Void) {
        lock.withLock { submitHook = hook }
    }

    /// Sends one event to an open stream. Does nothing for other requests.
    func emit(_ event: CBv2Event, to id: CBv2RequestID) {
        let continuation = lock.withLock { openStreams[id] }
        continuation?.yield(event)
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let reply = script(request)
        let hook = lock.withLock { () -> (@Sendable (CBv2Request) -> Void)? in
            _requests.append(request)
            return submitHook
        }
        let stream: AsyncStream<CBv2Event>
        switch reply {
        case .refuse(let message):
            throw ScriptedBenchmarkRefusal(message: message)
        case .events(let events, let gap) where gap == .zero:
            let (made, continuation) = AsyncStream<CBv2Event>.makeStream()
            for event in events { continuation.yield(event) }
            continuation.finish()
            stream = made
        case .events(let events, let gap):
            stream = AsyncStream { continuation in
                let task = Task {
                    for event in events {
                        try? await Task.sleep(for: gap)
                        continuation.yield(event)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        case .open(let events):
            let (made, continuation) = AsyncStream<CBv2Event>.makeStream()
            for event in events { continuation.yield(event) }
            lock.withLock { openStreams[request.id] = continuation }
            stream = made
        }
        hook?(request)
        return stream
    }

    func cancel(_ id: CBv2RequestID) {
        let continuation = lock.withLock { () -> AsyncStream<CBv2Event>.Continuation? in
            _cancelled.append(id)
            guard cancelReason != nil else { return nil }
            return openStreams.removeValue(forKey: id)
        }
        guard let continuation, let reason = cancelReason else { return }
        continuation.yield(.finished(
            reason: reason,
            usage: CBv2Usage(promptTokens: 0, completionTokens: 0)))
        continuation.finish()
    }

    func capacity() -> CBv2CapacitySnapshot { snapshot }

    func packedPrefillActivity() -> CBv2PackedPrefillActivity {
        lock.withLock { () -> CBv2PackedPrefillActivity in
            guard let first = packedReads.first else { return CBv2PackedPrefillActivity.none }
            if packedReads.count > 1 { packedReads.removeFirst() }
            return first
        }
    }

    func shutdown() async {
        let open = lock.withLock { () -> [AsyncStream<CBv2Event>.Continuation] in
            _shutdownCalls += 1
            defer { openStreams.removeAll() }
            return Array(openStreams.values)
        }
        for continuation in open { continuation.finish() }
    }
}

/// A delta event that carries `tokens` and no text or logprobs.
func scriptedDelta(_ tokens: [Int]) -> CBv2Event {
    .delta(text: "", tokens: tokens, logprobs: nil)
}

/// A terminal event with zero usage.
func scriptedFinish(_ reason: CBv2FinishReason) -> CBv2Event {
    .finished(reason: reason, usage: CBv2Usage(promptTokens: 0, completionTokens: 0))
}
