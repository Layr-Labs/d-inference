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
/// positions, so their bound here is the protocol's 65,536-token context
/// (up to 32,768 prompt tokens and 32,768 output tokens).
struct QwenResidentContextLimits: Equatable, Encodable {
    /// Prefill frames are at most this long; the attention transient and the
    /// boundary arrays are priced for one frame of it.
    static let chunkTokens = 512

    /// The model's declared context, or nil for the earlier reservation.
    let declaredContextTokens: Int?
    /// The longest prompt plus output one request may hold.
    let maximumContextTokens: Int
    /// Each leaves room for at least one token of the other. A request's own
    /// prompt plus output is held to `maximumContextTokens`.
    let maximumPromptTokens: Int
    let maximumOutputTokens: Int
    let maximumChunkTokens: Int

    /// The bounds a declared context is cut to. `standard` is the protocol's
    /// standard request (every family's, sized and qualified for it); a
    /// registered row that serves its native context names a wider ceiling,
    /// within the wire's (`ClusterWorkerLimits.wire*`).
    struct Ceiling: Equatable {
        let promptTokens: Int, outputTokens: Int, contextTokens: Int
        static let standard = Ceiling(promptTokens: ClusterWorkerLimits.promptTokens,
            outputTokens: ClusterWorkerLimits.outputTokens, contextTokens: ClusterWorkerLimits.contextTokens)
        /// The whole declared context, with `outputTokens` at most.
        static func native(outputTokens: Int) -> Ceiling {
            .init(promptTokens: ClusterWorkerLimits.wirePromptTokens, outputTokens: outputTokens,
                contextTokens: ClusterWorkerLimits.wireContextTokens)
        }
    }

    init(declaredContextTokens declared: Int, prefillChunkTokens: Int = Self.chunkTokens,
         ceiling: Ceiling = .standard) throws {
        guard declared >= 2, declared <= 1_048_576,
              (1...ClusterWorkerLimits.wirePromptTokens).contains(ceiling.promptTokens),
              (1...ClusterWorkerLimits.wireOutputTokens).contains(ceiling.outputTokens),
              (1...ClusterWorkerLimits.wireContextTokens).contains(ceiling.contextTokens),
              (1...ClusterWorkerLimits.promptTokens).contains(prefillChunkTokens) else {
            throw QwenDenseProfileError("Declared model context is outside the bounded metadata scope")
        }
        declaredContextTokens = declared
        maximumContextTokens = min(ceiling.contextTokens, declared)
        maximumPromptTokens = min(ceiling.promptTokens, maximumContextTokens - 1)
        maximumOutputTokens = min(ceiling.outputTokens, maximumContextTokens - 1)
        maximumChunkTokens = min(prefillChunkTokens, maximumPromptTokens)
    }

    /// The earlier fixed profile every model had (8,192 prompt, 128 output,
    /// 8,320 context, frames of 512): what a model keeps until the context its
    /// configuration declares is recorded.
    static let reservation = QwenResidentContextLimits(prompt: 8192, output: 128, context: 8320, chunk: chunkTokens)

    /// A declared context's limits, or the reservation when none is recorded.
    static func derived(declaredContextTokens declared: Int?) throws -> QwenResidentContextLimits {
        try declared.map { try QwenResidentContextLimits(declaredContextTokens: $0) } ?? .reservation
    }

    private init(prompt: Int, output: Int, context: Int, chunk: Int) {
        declaredContextTokens = nil; maximumContextTokens = context
        maximumPromptTokens = prompt; maximumOutputTokens = output; maximumChunkTokens = chunk
    }
}
