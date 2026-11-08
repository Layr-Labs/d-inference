// A streamed local request's response head waits for the engine to admit the request.

import Foundation
import MLXLMCommon

/// Whether a streamed local request's head waits for engine admission (`EngineV2Bridge.holdHeadUntilAdmitted`).
/// `LocalChatUploadResponder` turns it off for a raw-body owner's request whose logprobs ride a side channel: that
/// channel is spliced into frames as the stream is read, so a stream read only after its tokens were buffered would
/// carry entries for tokens it shouldn't.
enum LocalHeadHold {
    @TaskLocal static var enabled = true
}

extension EngineV2Bridge {
    /// A held head (`heldHeads`): the request still waits for the engine to admit it, or the engine ended it before
    /// admitting it for this Mac's memory.
    enum HeldHead {
        case waiting
        case refused(String)
    }

    /// Holds a streamed local request (`submitTokenized`) until the engine admits it: until it no longer waits in the
    /// engine's queue (`queueState(of:)`, the same inference me first uses), its first token, or its end. Its response
    /// head goes out only after this returns.
    /// - If the engine ended it before admitting it for this Mac's memory, at its 120 s admission lease or after a full
    ///   paged pool's requeues (`recordHeadHoldRefusal`), this throws `tokenBudgetExhausted`, which the local API
    ///   answers with the memory 503 before any SSE header. Any other end returns, and the stream carries it as before.
    /// - The held head never outlives the admission lease: a request the engine never admits ends when its lease runs
    ///   out, and the hold with it. One that reads as waiting after its admission (an older request preempted to the
    ///   front of the queue) is held until its first token.
    /// - A client that leaves during the hold cancels the request.
    /// - The first look is at once, the next `headHoldFirstRecheck` later, and the wait doubles up to
    ///   `queuePollInterval`. The engine counts a request as waiting from its submit until the step that admits it
    ///   publishes, so the first look always reads waiting; a request the engine admits at its next step gets its
    ///   head a few milliseconds after its submit, and a queued one is looked at every `queuePollInterval`. Nothing
    ///   runs per token.
    func holdHeadUntilAdmitted(id: String) async throws {
        defer { heldHeads.removeValue(forKey: id) }
        var wait = min(Self.headHoldFirstRecheck, queuePollInterval)
        while true {
            if case .refused(let message)? = heldHeads[id] {
                throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(message)
            }
            guard let queue = queueState(of: id), queue.waiting else { return }
            do {
                try await Task.sleep(for: wait)
            } catch {
                cancel(requestId: id)
                throw error
            }
            wait = min(wait * 2, queuePollInterval)
        }
    }

    /// The hold's first wait after its first look: an idle engine steps within a millisecond (EngineV2's idle
    /// recheck), and a busy one at its next step.
    static let headHoldFirstRecheck: Duration = .milliseconds(1)

    /// The pump's terminal for a request whose head is held: an end before admission for this Mac's memory becomes
    /// the hold's refusal. Called in the actor turn that records the terminal, so the hold finds the refusal no later
    /// than it finds the request gone. Once per request, at its terminal.
    func recordHeadHoldRefusal(id: String, reason: CBv2FinishReason) {
        guard heldHeads[id] != nil else { return }
        switch reason {
        case .terminal(cause: .admissionTimeout, _):
            heldHeads[id] = .refused(
                "token_budget_exhausted: the engine couldn't admit the request within its admission lease")
        case .error(let message) where message.hasPrefix(CBv2KVError.capacityExhaustedFinishPrefix):
            heldHeads[id] = .refused("token_budget_exhausted: KV capacity exhausted after requeues")
        default:
            return
        }
    }
}
