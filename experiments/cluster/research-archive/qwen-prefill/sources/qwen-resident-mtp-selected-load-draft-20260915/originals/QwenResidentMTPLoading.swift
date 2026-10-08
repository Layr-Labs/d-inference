import Foundation
import MLX
@_spi(Cluster) import MLXLLM
import MLXLMCommon
import MLXNN

struct QwenResidentMTPLoadReceipt: Encodable {
    let placement: QwenResidentMTPPlacement
    let targetLoadReceiptSHA256: String
    let loadedTensorBytes: Int
    let allocatorReservedTensorBytes: Int
    let sourceReadAccounting: CheckpointAlignedReadAccounting
    let independentlyOwnedAdditionalBuffers = true
    let sharesTargetFinalNormAndOutputHead = true
    let targetResidualEmbeddingUnchanged = true
    let generationEnabled = false
    let requestHistoryAllocated = false
}

/// Native-only storage owner. No serving/worker/protocol entry consumes this
/// value yet. The assistant retains the final target and its explicit replica;
/// no Module/array escapes the future private resident execution owner.
struct QwenResidentStageWithMTPAssets {
    let target: QwenResidentLoadedStage
    let assistant: Qwen35InlineMTPAssistant
    let receipt: QwenResidentMTPLoadReceipt
}

/// Separate opt-in storage preparation, not an MTP generation switch. The
/// ordinary loadQwenResidentStage entry does not call this function.
func loadQwenResidentStageWithMTPAssets(_ admission: QwenResidentAdmission,
    check: () throws -> Void
) throws -> QwenResidentStageWithMTPAssets {
    try MLX.withError { nativeError in
        func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
        do {
            return try autoreleasepool {
                let source = try PreparedQwenResidentMTPSource(admission: admission, check: checked)
                let loaded = try loadPreparedQwenResidentStage(admission, prepared: source.target,
                    additional: source.resources, check: checked)
                guard loaded.loaded.stageIndex == 1, loaded.loaded.plan.fingerprint == admission.plan.fingerprint else {
                    throw ProbeError("MTP target is not the admitted final stage")
                }
                let originalLayout = modelParameterLayout(loaded.loaded.model)
                let reader = QwenResidentMTPMaterializer(source: source)
                // Lazy defaults are individually replaced without eval(embedding).
                // This object is separate from the residual-ingress placeholder.
                let embedding = QuantizedEmbedding(embeddingCount: loaded.profile.vocabularySize,
                    dimensions: loaded.profile.geometry.hiddenSize, groupSize: 64, bits: 4, mode: .affine)
                for entry in source.placement.embedding {
                    let suffix = String(entry.name.dropFirst(QwenResidentMTPPlacement.embeddingRoot.count + 1))
                    let value = try reader.read(entry.name, shape: entry.shape,
                        packed: entry.sourceDType == "U32", check: checked)
                    try embedding.update(parameters: ModuleParameters.unflattened([suffix: value]),
                        verify: [.noUnusedKeys, .shapeMismatch])
                    try checked()
                }
                embedding.freeze()
                let names = Set(source.placement.head.map { String($0.name.dropFirst(4)) })
                let assistant = try Qwen35InlineMTPAssistant.loadVerifiedInline(
                    configuration: admission.configBytes, target: loaded.loaded.model,
                    inputEmbedding: embedding, parameterNames: names, verificationMode: .serialTarget,
                    read: { name, shape, dtype in
                        try reader.read("mtp." + name, shape: shape, packed: dtype == .uint32, check: checked)
                    }, check: checked)
                try reader.finish(); try checked()
                guard modelParameterLayout(loaded.loaded.model) == originalLayout,
                      let target = loaded.loaded.model as? any CBv2RecurrentMTPForwardable,
                      assistant.targetIdentity == target.cbv2MTPTargetIdentity else {
                    throw ProbeError("MTP loading changed target storage or bound another target")
                }
                return .init(target: loaded, assistant: assistant,
                    receipt: .init(placement: source.placement,
                        targetLoadReceiptSHA256: sha256(try canonicalJSONData(loaded.loaded.receipt)),
                        loadedTensorBytes: reader.loadedBytes,
                        allocatorReservedTensorBytes: source.resources.reservedTensorBytes,
                        sourceReadAccounting: reader.accounting))
            }
        } catch {
            // Same recorded-native-fault precedence as the resident load owner.
            try nativeError.check()
            throw error
        }
    }
}

