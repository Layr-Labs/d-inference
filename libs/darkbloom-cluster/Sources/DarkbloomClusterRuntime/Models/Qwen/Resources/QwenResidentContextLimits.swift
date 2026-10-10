import DarkbloomClusterProtocol
import Foundation

/// The request bounds of one registered model, derived instead of tabulated:
/// the worker protocol's own bounds, cut to the context the model declares in
/// its pinned configuration (`max_position_embeddings`). Model-independent: a
/// family's adapter passes its own declared context. Nothing here is a memory
/// grant; the host memory gate decides, per request and live, whether a
/// context fits on the Mac that would hold it (`QwenResidentContextAdmission`).
///
/// 8,192 prompt tokens was the earlier reservation of every profile, not a
/// property of the models: the registered dense Qwen models declare 262,144
/// positions, so their bound here is the protocol's 32,768-token context.
struct QwenResidentContextLimits: Equatable, Encodable {
    /// Prefill frames are at most this long; the attention transient and the
    /// boundary arrays are priced for one frame of it.
    static let chunkTokens = 512

    let declaredContextTokens: Int
    /// The longest prompt plus output one request may hold.
    let maximumContextTokens: Int
    /// Each leaves room for at least one token of the other. A request's own
    /// prompt plus output is held to `maximumContextTokens`.
    let maximumPromptTokens: Int
    let maximumOutputTokens: Int
    let maximumChunkTokens: Int

    init(declaredContextTokens declared: Int) throws {
        guard declared >= 2, declared <= 1_048_576 else {
            throw QwenDenseProfileError("Declared model context is outside the bounded metadata scope")
        }
        declaredContextTokens = declared
        maximumContextTokens = min(ClusterWorkerLimits.contextTokens, declared)
        maximumPromptTokens = min(ClusterWorkerLimits.promptTokens, maximumContextTokens - 1)
        maximumOutputTokens = min(ClusterWorkerLimits.outputTokens, maximumContextTokens - 1)
        maximumChunkTokens = min(Self.chunkTokens, maximumPromptTokens)
    }
}
