import Foundation

/// Explicit interoperability geometry. This does not admit a model, resource
/// budget, wire flow, transport, or execution mode on its own.
enum QwenLayerStagePrefillProfile: String, Codable, CaseIterable {
    case longPrefill8KV1 = "long_prefill_8k_v1"

    var maximumPromptCount: Int { 8192 }
    var maximumChunkSize: Int { 512 }
    var maximumPrefillFrames: Int { 128 }
    var maximumHiddenSize: Int { 8192 }
    var maximumVocabularySize: Int { 262_144 }

    var fingerprint: String {
        sha256(Data([
            "qwen-stage-prefill-profile-v1", rawValue,
            "batch=1", "prompt=1...8192", "chunk=1...512", "output=1", "teacher=0",
            "frames=1...128", "hidden=1...8192", "vocabulary=1...262144",
            "floatingDTypes=float16,bfloat16,float32",
        ].joined(separator: "\n").utf8))
    }

    /// Subtract-before-divide avoids a prompt+chunk-1 overflow. All arithmetic
    /// is checked before the resulting geometry can enter an admitted request.
    func admit(batchSize: Int, promptCount: Int, chunkSize: Int,
               outputCount: Int) throws -> (prefillFrameCount: Int, maximumTokens: Int) {
        guard batchSize == 1, (1...maximumPromptCount).contains(promptCount),
              (1...maximumChunkSize).contains(chunkSize), outputCount == 1 else {
            throw ProbeError("Long prefill requires an explicit batch-one profile, prompt<=8192, chunk<=512 and output one")
        }
        let quotient = (promptCount - 1) / chunkSize
        let (frames, frameOverflow) = quotient.addingReportingOverflow(1)
        let (maximumTokens, tokenOverflow) = promptCount.addingReportingOverflow(outputCount)
        guard !frameOverflow, !tokenOverflow, (1...maximumPrefillFrames).contains(frames) else {
            throw ProbeError("Long prefill exceeds its checked 128-frame or reserved-token geometry")
        }
        return (frames, maximumTokens)
    }
}
