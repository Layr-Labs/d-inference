import Foundation

/// The serial request loop calls this factory at most once. It binds the
/// admitted local frame before returning a CPU-only observer to a native owner.
func qwenPrefillOwnerObserverFactory(recorder: QwenPrefillOwnerRecorder) -> QwenPrefillOwnerObserverFactory {
    var acquired = false
    return { frame in
        let identity = recorder.identity
        guard !acquired, frame.phase == .prefill, !frame.finalPromptChunk,
              frame.sequence == identity.frameSequence, frame.tokenOffset == identity.tokenOffset,
              frame.tokenCount == identity.tokenCount else {
            recorder.fail()
            throw QwenPrefillOwnerError("Selected owner observer requires one exact admitted frame")
        }
        acquired = true
        return { try recorder.observe($0) }
    }
}
