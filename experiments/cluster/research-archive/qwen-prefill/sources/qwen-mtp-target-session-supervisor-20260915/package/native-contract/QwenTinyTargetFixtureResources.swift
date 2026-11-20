#if QWEN_TARGET_TINY_FIXTURE
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Authority is minted from actual private fixture-owned stage objects. Neither
/// a caller byte count nor a fabricated registered profile can construct it.
final class QwenTinyTargetFixtureResources {
    struct Ledger: Encodable {
        let maximumTokens: Int, chunkTokens: Int, simultaneousPairs: Int
        let perPairLogicalStateAndBoundaryBytes: Int
        let roundedStateAndBoundaryBytes: Int, fusionBytes: Int
        let comparisonNativeBytes: Int, comparisonHostBytes: Int
        let transactionNativeBytes: [Int], transactionHostBytes: [Int]
        let wholeProcessBound = false
    }
    let model: QwenTinyTargetModel
    let request: QwenLayerStageGenerationRequest
    let ledger: Ledger
    private let base: QwenResidentRequestAllowance
    private let increments: [QwenTargetVerificationBudget]
    private let check: () throws -> Void

    init(model: QwenTinyTargetModel, request: QwenLayerStageGenerationRequest,
         check: @escaping () throws -> Void) throws {
        guard request.promptTokenIDs == [1, 2, 3, 4, 5], request.chunkSize == 2,
              [2, 4].contains(request.outputCount), request.profile.hiddenSize == 64,
              request.profile.vocabularySize == 128, request.profile.activationDType == "float32" else {
            throw ProbeError("Tiny authority requires its exact bounded geometry")
        }
        try check(); try QwenResidentResourceEnvironment.require()
        let g = try QwenLongPrefillBudgetGeometry(layers: 8, fullAttentionInterval: 4, hiddenSize: 64,
            queryHeads: 1, kvHeads: 1, headDimension: 64, linearKeyHeads: 1, linearValueHeads: 1,
            linearKeyDimension: 32, linearValueDimension: 32, convolutionKernel: 4)
        let b = try QwenLongPrefillTensorBudget.estimate(geometry: g,
            maximumTokens: request.maximumTokens, chunkSize: request.chunkSize)
        for stage in model.stages {
            try model.requireStage(stage)
            let actual = try CBv2RequestGeometry(model: stage.model, family: .qwen35,
                feedForwardKind: "dense", layerCount: stage.layerCount, vocabularySize: 128,
                configurationData: stage.configurationData, maximumTokens: request.maximumTokens)
            guard stage.layerCount == 4, actual.kinds.count == 1, actual.kvDType == .float32,
                  actual.kinds[0].modelLayerIndex == 3, actual.kinds[0].headDim == 64,
                  actual.kinds[0].kvHeads == 1, actual.kinds[0].queryHeads == 1,
                  actual.kvCapacityBytes == b.kvCapacityBytesPerAttentionLayer,
                  actual.recurrent.modelLayerIndices == [0, 1, 2],
                  actual.recurrent.layers.allSatisfy({ $0.convShape == [1, 3, 96] && $0.convDType == .float32
                    && $0.ssmShape == [1, 1, 32, 32] && $0.ssmDType == .float32 }),
                  try actual.recurrent.fixedBytesPerRequest() == 3 * (b.convolutionBytesPerLayer + b.ssmBytesPerLayer),
                  !stage.model.leafModules().flattened().contains(where: { $0.1 is QuantizedLinear || $0.1 is QuantizedEmbedding }) else {
                throw ProbeError("Actual tiny model geometry/fusion policy differs from its named ledger")
            }
        }
        let sum = QwenLongPrefillCheckedBytes.sum, product = QwenLongPrefillCheckedBytes.product
        func array(_ bytes: Int, _ count: Int) throws -> Int {
            try product([QwenResidentResourceEnvironment.allocationBound(bytes), count])
        }
        // Two simultaneous complete two-stage requests: ordinary and target.
        // Each has 3 recurrent generations, full KV/offsets, one snapshot and
        // two prefill boundaries. Unquantized projections cannot take the
        // private QuantizedLinear fusion branch in Qwen35.swift.
        let perPair = try sum([array(b.convolutionBytesPerLayer, 3*b.recurrentLayers),
            array(b.ssmBytesPerLayer, 3*b.recurrentLayers),
            array(b.kvCapacityBytesPerAttentionLayer/2, 2*b.attentionLayers),
            array(4, b.attentionLayers), array(b.largestSingleHostStateComponentBytes, 1), array(b.boundaryBytes, 2)])
        let state = try product([perPair, 2])
        let comparisonNative = try array(128*4, 4), comparisonHost = 128*4*2
        let increments = try [0, 1].map { rank in
            try QwenTargetVerificationBudget.derive(hiddenSize: 64, vocabularySize: 128, dtypeBytes: 4, rank: rank,
                steps: min(2, request.outputCount-1), bound: QwenResidentResourceEnvironment.allocationBound)
        }
        base = .init(stateBytes: state, fusionBytes: 0, reservedBytes: try sum([state, comparisonNative]))
        self.model = model; self.request = request; self.check = check; self.increments = increments
        ledger = .init(maximumTokens: request.maximumTokens, chunkTokens: 2, simultaneousPairs: 2,
            perPairLogicalStateAndBoundaryBytes: b.conservativeStateAndBoundaryBytes,
            roundedStateAndBoundaryBytes: state, fusionBytes: 0,
            comparisonNativeBytes: comparisonNative, comparisonHostBytes: comparisonHost,
            transactionNativeBytes: increments.map(\.additionalNativeBytes), transactionHostBytes: increments.map(\.additionalHostBytes))
        try requireLive()
    }

    func requireLive() throws {
        try check()
        try base.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum(increments.map(\.additionalNativeBytes)),
            additionalHostBytes: QwenLongPrefillCheckedBytes.sum(increments.map(\.additionalHostBytes) + [ledger.comparisonHostBytes]))
        try check()
    }

    func authority(stage: LoadedQwenLayerStage, request: QwenTargetVerificationRequest) throws -> QwenTinyTargetVerificationResources {
        try model.requireStage(stage)
        guard request.agreement.request == self.request,
              request.agreement.descriptor.storageCommitmentSHA256 == stage.receipt.storageCommitmentSHA256 else {
            throw ProbeError("Tiny resource authority belongs to a different request/source")
        }
        try requireLive()
        return .init(scope: self, budget: increments[stage.stageIndex])
    }
}

struct QwenTinyTargetVerificationResources {
    private let scope: QwenTinyTargetFixtureResources
    let budget: QwenTargetVerificationBudget
    fileprivate init(scope: QwenTinyTargetFixtureResources, budget: QwenTargetVerificationBudget) {
        self.scope = scope; self.budget = budget
    }
    func requireLive(ownerCheck: (QwenTargetVerificationBudget) throws -> Void) throws {
        try scope.requireLive(); try ownerCheck(budget); try scope.requireLive()
    }
}
#endif
