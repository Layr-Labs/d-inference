import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Gemma 4's assistant drafter (Google's MTP "assistant" checkpoint, the one
/// the single-Mac product loads for `gemma-4-26b-qat-4bit`) on a tensor-parallel
/// rank, or on the whole model. Every rank holds the assistant whole and runs
/// the product's own CBv2 drafter adapter (`Gemma4CBv2MTPDrafter`) over a
/// mirror of the target's keys and values of the two layers the assistant
/// reads (`Gemma4TensorParallelDraftMirror`), so its proposals are the ones
/// the single-Mac drafter makes from the same state. Proposals never decide a
/// token: the target's verify window does (`Gemma4VerifyWindow`).
public final class Gemma4TensorParallelAssistant {
    /// Bound into the load agreement beside the depth.
    public static let agreementName = "gemma4-tp-assistant-rounds-v1"
    /// Proposals a round makes at most (the window is the last token plus these).
    public static let maximumDepth = 4

    let assistant: Gemma4AssistantDraftModel
    let drafter: Gemma4CBv2MTPDrafter
    let depth: Int
    private let target: DraftTarget

    /// The rank's view the drafter binds to: the whole model's text
    /// configuration (what the assistant is checked against) and the rank's
    /// replicated token embedding (the "target embedding" of each draft step).
    final class DraftTarget: Gemma4MTPTarget {
        let configuration: Gemma4TextConfiguration
        let text: Gemma4TextModel
        init(configuration: Gemma4TextConfiguration, text: Gemma4TextModel) {
            self.configuration = configuration; self.text = text
        }
        var mtpConfiguration: Gemma4TextConfiguration { configuration }
        func embedTokensForDrafter(_ tokens: MLXArray) -> MLXArray { text.embedTokensForDrafter(tokens) }
        func mtpNewCache(parameters: GenerateParameters?) -> [any KVCache] {
            preconditionFailure("A tensor-parallel draft target owns no caches")
        }
        func forwardForMTP(_ tokens: MLXArray, cache: [KVCache]) -> Gemma4MTPForward {
            preconditionFailure("A tensor-parallel draft target runs no target forward")
        }
        func rollbackSpeculativeCache(_ caches: [KVCache], accepted: Gemma4AcceptCount, blockSize: Int) {
            preconditionFailure("A tensor-parallel draft target owns no caches")
        }
    }

    public init(assistant: Gemma4AssistantDraftModel, model: Gemma4TensorParallelModel, depth: Int) throws {
        guard (1 ... Self.maximumDepth).contains(depth) else {
            throw ProbeError("Gemma tensor-parallel assistant depth must be 1 to \(Self.maximumDepth)")
        }
        let target = DraftTarget(configuration: model.fullTextConfiguration, text: model.textModel)
        self.drafter = try Gemma4CBv2MTPDrafter(drafter: assistant, target: target)
        self.assistant = assistant; self.target = target; self.depth = depth
        _ = try Gemma4VerifyWindow.sourceLayers(model.fullTextConfiguration)
    }

    /// Up to `count` greedy proposals after `token` (whose target hidden is
    /// `hidden`, `[1, 1, H]`) from `capture`: a `[count]` int32 graph, not
    /// evaluated.
    func propose(token: Int, hidden: MLXArray, capture: CBv2MTPRowCapture, count: Int) -> MLXArray {
        let prepared = drafter.prepare(rows: [capture])
        var input = MLXArray([Int32(token)]).reshaped([1, 1])
        var carried = hidden
        var proposals: [MLXArray] = []
        for _ in 0 ..< count {
            let (next, nextHidden) = drafter.draftStep(tokens: input, hidden: carried, prepared: prepared)
            proposals.append(next.reshaped([1]))
            input = next.reshaped([1, 1]); carried = nextHidden
        }
        return concatenated(proposals, axis: 0)
    }
}

/// One request's mirror of the target's keys and values of the assistant's
/// two source layers (the last sliding-window and the last full-attention
/// layer), every KV head: a rank holds only its own heads of those layers, so
/// each round's new rows of the other rank's heads arrive in the round's
/// agreement (and the prompt's in one exchange after it). Heads in rank order,
/// as the plan cuts them (contiguous halves). Committed positions only; the
/// sliding layer keeps a window and a margin.
final class Gemma4TensorParallelDraftMirror {
    let slidingWindow: Int
    private(set) var full: (keys: MLXArray, values: MLXArray)?
    private(set) var sliding: (keys: MLXArray, values: MLXArray)?
    /// Committed positions the full mirror holds: `[0, count)`.
    private(set) var count = 0
    /// Positions the sliding mirror holds: `[slidingStart, count)`.
    private(set) var slidingStart = 0

    init(slidingWindow: Int) { self.slidingWindow = slidingWindow }

    /// Appends `rows` committed positions: each layer's whole-head rows
    /// `[1, heads, rows, D]` (graphs).
    func append(full rows: (keys: MLXArray, values: MLXArray), sliding slidingRows: (keys: MLXArray, values: MLXArray),
                positions: Int) {
        precondition(rows.keys.dim(2) == positions && slidingRows.keys.dim(2) == positions)
        if let full {
            self.full = (concatenated([full.keys, rows.keys], axis: 2), concatenated([full.values, rows.values], axis: 2))
        } else {
            full = rows
        }
        if let held = sliding {
            var keys = concatenated([held.keys, slidingRows.keys], axis: 2)
            var values = concatenated([held.values, slidingRows.values], axis: 2)
            let length = keys.dim(2), keep = slidingWindow + 64
            if length > keep + 64 {
                keys = keys[0..., 0..., (length - keep)...]; values = values[0..., 0..., (length - keep)...]
                slidingStart += length - keep
            }
            sliding = (keys, values)
        } else {
            sliding = slidingRows
        }
        count += positions
    }

    /// Starts the mirror at a committed frontier: the full layer's whole
    /// history and the sliding layer's retained window ending there.
    func start(full rows: (keys: MLXArray, values: MLXArray), sliding slidingRows: (keys: MLXArray, values: MLXArray),
               frontier: Int) {
        precondition(full == nil && rows.keys.dim(2) == frontier && slidingRows.keys.dim(2) <= frontier)
        full = rows; sliding = slidingRows
        count = frontier; slidingStart = frontier - slidingRows.keys.dim(2)
    }

    /// The single-Mac drafter's capture at the committed frontier: the whole
    /// full history and the sliding layer's last `retained` positions (the
    /// count the target's own sliding row retains there).
    func capture(retained: Int) throws -> CBv2MTPRowCapture {
        guard let full, let sliding, retained >= 1, retained <= count - slidingStart, full.keys.dim(2) == count else {
            throw ProbeError("Gemma draft mirror does not hold the target's frontier")
        }
        let from = count - slidingStart - retained
        return CBv2MTPRowCapture(fullKeys: full.keys, fullValues: full.values,
            slidingKeys: sliding.keys[0..., 0..., from...], slidingValues: sliding.values[0..., 0..., from...],
            slidingStart: count - retained, anchor: count)
    }

    var evaluationTargets: [MLXArray] {
        [full?.keys, full?.values, sliding?.keys, sliding?.values].compactMap { $0 }
    }
}
