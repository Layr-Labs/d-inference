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
    /// Holds a streamed local request (`submitTokenized`) until the engine admits it: until it no longer waits in the
    /// engine's queue (`ownerWaitView`, the same inference me first uses), or its first token, or its end. Its response
    /// head goes out only after this returns. If the engine ended it before admitting it for this Mac's memory, its
    /// 120 s admission lease or a full paged pool's requeues (`recordHeadHoldRefusal`), this throws
    /// `tokenBudgetExhausted`, which the local API answers with the memory 503 before any SSE header. Any other end
    /// returns, and the stream carries it as before. The admission lease bounds the wait; nothing runs per token.
    func holdHeadUntilAdmitted(id: String) async throws {
        defer {
            headHeldIDs.remove(id)
            headHoldRefusals.removeValue(forKey: id)
        }
        while true {
            if let refusal = headHoldRefusals.removeValue(forKey: id) {
                throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(refusal)
            }
            guard let view = ownerWaitView(id: id), view.waiting else { return }
            do {
                try await Task.sleep(for: ownerWaitPollInterval)
            } catch {
                cancel(requestId: id)
                throw error
            }
        }
    }

    /// The pump's terminal for a request whose head is held: an end before admission for this Mac's memory becomes
    /// the hold's refusal. Called before the terminal is recorded, in the same actor turn.
    func recordHeadHoldRefusal(id: String, reason: CBv2FinishReason) {
        guard headHeldIDs.contains(id) else { return }
        switch reason {
        case .terminal(cause: .admissionTimeout, _):
            headHoldRefusals[id] =
                "token_budget_exhausted: the engine couldn't admit the request within its admission lease"
        case .error(let message) where message.hasPrefix(CBv2KVError.capacityExhaustedFinishPrefix):
            headHoldRefusals[id] = "token_budget_exhausted: KV capacity exhausted after requeues"
        default:
            return
        }
    }
}
