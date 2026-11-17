// A local request that reaches its overall deadline is answered busy, not as a failed generation.

import Foundation

/// A local request's end at its overall deadline: the engine's safety ceiling on one Mac (or its legacy total wall,
/// `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT`), and a pair's request deadline. The local API answers it as busy, in
/// `LocalMemoryRefusal.deadline` with code `capacity_busy`: a 503 with `Retry-After` before any SSE header, or, once
/// a stream has started, its error chunk in those words, never "Response generation failed". The local API binds one
/// per request (`CORSResponder`) and the engine marks it (`MultiModelBatchSchedulerEngine`); a coordinator request has
/// none and keeps its typed terminal.
final class LocalDeadlineOutcome: @unchecked Sendable {
    @TaskLocal static var current: LocalDeadlineOutcome?

    private let lock = NSLock()
    private var isReached = false

    var reached: Bool { lock.withLock { isReached } }

    func markReached() { lock.withLock { isReached = true } }

    /// Whether an engine's typed end is the request's overall deadline.
    static func isDeadline(_ cause: InferenceTerminalCause) -> Bool {
        false
    }

    /// Whether an engine's untyped end is its legacy total wall (`CBv2TerminalCause.legacyRequestTimeout`).
    static func isLegacyDeadline(_ message: String) -> Bool {
        false
    }

    /// `frames`, with the failure frame of a request that reached its deadline answered busy.
    static func answeringBusy(_ frames: AsyncThrowingStream<String, Error>,
                              outcome: LocalDeadlineOutcome?) -> AsyncThrowingStream<String, Error> {
        frames
    }

    /// The shared pipeline's failure frame (`finish_reason: "error"` and an error object) with its error in the busy
    /// words; nil for any other frame.
    static func busyFrame(replacing frame: String) -> String? {
        nil
    }
}
