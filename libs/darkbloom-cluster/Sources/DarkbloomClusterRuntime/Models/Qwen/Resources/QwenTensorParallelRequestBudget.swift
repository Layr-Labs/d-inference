import DarkbloomClusterPlacement
import Foundation

/// A complete TP request ledger derived from the same canonical inventory
/// used at LOAD. No weights are loaded, and the allocator bound is explicit.
/// All heads and fused banks are conservatively charged on each rank.
struct QwenTensorParallelRequestBudget {
    let stateBytes: Int
    let fusionBytes: Int
    let transientBytes: Int
    let logitsBytes: Int
    let projectionConstantBytes: Int
    let allowance: ClusterTensorParallelRequestAllowance

    static func derive(geometry g: QwenLongPrefillBudgetGeometry, plan: QwenTensorParallelPlan,
                       tensors: [QwenDenseCanonicalTensor], maximumTokens: Int, chunkSize: Int,
                       allocationBound: (Int) throws -> Int) throws -> Self {
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        guard g.hiddenSize == plan.hiddenSize, g.layers == plan.layerCount,
              g.fullAttentionInterval == plan.fullAttentionInterval,
              Set(tensors.map(\.name)).count == tensors.count else {
            throw ProbeError("Tensor-parallel request geometry or canonical inventory differs")
        }
        func bound(_ logical: Int, count: Int = 1) throws -> Int {
            let allocated = try allocationBound(logical)
            guard logical > 0, allocated >= logical, count >= 0 else {
                throw ProbeError("Tensor-parallel request allocator bound is invalid")
            }
            return try product([allocated, count])
        }
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: g,
            maximumTokens: maximumTokens, chunkSize: chunkSize)
        let state = try sum([
            bound(budget.convolutionBytesPerLayer, count: 3 * budget.recurrentLayers),
            bound(budget.ssmBytesPerLayer, count: 3 * budget.recurrentLayers),
            bound(budget.kvCapacityBytesPerAttentionLayer / 2, count: 2 * budget.attentionLayers),
            bound(4, count: budget.attentionLayers),
            bound(budget.largestSingleHostStateComponentBytes),
            bound(budget.boundaryBytes, count: 2),
        ])
        let inventory = Dictionary(uniqueKeysWithValues: tensors.map { ($0.name, $0) })
        // FP32 row projections retain widened affine scales and offsets in
        // ConstantArrayCastCache, outside the parameter tree. LOAD has not run
        // a forward yet, so its active-byte observation does not include them.
        // Charge the full bank on each rank, independently bounding every cast.
        var constants = 0
        for path in plan.inputColumnModulePaths() {
            for suffix in ["scales", "biases"] {
                let key = path + "." + suffix
                guard let tensor = inventory[key], ["BF16", "F16", "F32"].contains(tensor.sourceDType),
                      !tensor.shape.isEmpty, tensor.shape.allSatisfy({ $0 > 0 }) else {
                    throw ProbeError("Tensor-parallel request lacks canonical projection constant \(key)")
                }
                let elements = try product(tensor.shape)
                let sourceBytes = tensor.sourceDType == "F32" ? 4 : 2
                guard tensor.byteCount == (try product([elements, sourceBytes])) else {
                    throw ProbeError("Tensor-parallel projection constant byte conservation differs")
                }
                if sourceBytes < 4 {
                    constants = try sum([constants, bound(product([elements, 4]))])
                }
            }
        }
        var fusion = 0
        for layer in 0..<plan.layerCount where (layer + 1) % plan.fullAttentionInterval != 0 {
            for suffix in ["weight", "scales", "biases"] {
                let parts = try ["in_proj_qkv", "in_proj_z", "in_proj_b", "in_proj_a"].map { projection in
                    let key = "language_model.model.layers.\(layer).linear_attn.\(projection).\(suffix)"
                    guard let tensor = inventory[key] else {
                        throw ProbeError("Tensor-parallel request lacks canonical fusion input \(key)")
                    }
                    return tensor
                }
                let dtype = suffix == "weight" ? "U32" : "BF16"
                guard let first = parts.first, first.shape.count == 2,
                      parts.allSatisfy({ $0.sourceDType == dtype && $0.shape.count == 2
                                       && $0.shape[1] == first.shape[1] }) else {
                    throw ProbeError("Tensor-parallel fusion shape or dtype differs")
                }
                let logical = try product([sum(parts.map { $0.shape[0] }), first.shape[1], suffix == "weight" ? 4 : 2])
                guard logical == (try sum(parts.map(\.byteCount))) else {
                    throw ProbeError("Tensor-parallel fusion byte conservation differs")
                }
                fusion = try sum([fusion, bound(logical)])
            }
        }
        let transientLogical = try QwenResidentPrefillTransient.bytes(geometry: g,
            stageHasAttention: budget.attentionLayers > 0, chunkTokens: chunkSize, contextTokens: maximumTokens)
        let transient = transientLogical == 0 ? 0 : try bound(transientLogical)
        let logits = try bound(product([plan.vocabularySize, 4]), count: 3)
        let payload = try product([chunkSize, plan.maximumPartialBytesPerToken])
        let frame = try sum([payload, QwenTensorParallelSealCodec.frameOverhead])
        let allowance = try ClusterTensorParallelRequestAllowance(maximumContextTokens: maximumTokens,
            maximumChunkTokens: chunkSize, requestBytesExcludingCollectives: sum([state, fusion, transient, logits, constants]),
            maximumCollectivePayloadBytes: payload, maximumCollectiveFrameBytes: frame,
            allocationBound: allocationBound)
        return .init(stateBytes: state, fusionBytes: fusion, transientBytes: transient,
                     logitsBytes: logits, projectionConstantBytes: constants, allowance: allowance)
    }
}
