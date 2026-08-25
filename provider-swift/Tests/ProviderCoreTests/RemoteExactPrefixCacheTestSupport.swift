import Foundation
import MLX
import MLXLMCommon

final class RemoteExactHybridFixtureModel: CBv2RecurrentSteppableModel {
    let recurrentStateSpec: CBv2RecurrentStateSpec? = .init(layers: [
        .init(
            modelLayerIndex: 0,
            convShape: [1, 1, 1],
            convDType: .float32,
            ssmShape: [1, 1, 1, 1],
            ssmDType: .float32)
    ])

    let cbv2Capabilities = CBv2ModelCapabilities(
        supportsPrefixReuse: false,
        supportsExactStatePrefixReuse: true,
        supportsPromptStateForking: false,
        supportsPagedKV: false,
        supportsCompiledDecode: false,
        supportsPackedPrefill: false,
        supportsMTP: false)

    private let lock = NSLock()
    private var _prefillRows = 0

    var prefillRows: Int {
        lock.withLock { _prefillRows }
    }

    func prefill(
        tokens: MLXArray,
        inputEmbeddings: MLXArray?,
        caches: [CBv2AttendingLayerCache],
        requirement: CBv2PrefillRequirement
    ) -> MLXArray {
        preconditionFailure("fixture requires request-owned recurrent prefill")
    }

    func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
        preconditionFailure("fixture requires request-owned recurrent state")
    }

    func forward(
        tokens: MLXArray,
        caches: [CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation]
    ) -> MLXArray {
        let batch = tokens.dim(0)
        let length = tokens.dim(1)
        precondition(caches.count == 1)
        precondition(recurrentState.count == batch)
        if length > 1 {
            lock.withLock { _prefillRows += batch }
        }

        let tokenValues = tokens.asType(.float32)
        let queries = (tokenValues + 1).reshaped([batch, 1, length, 1])
        let keys = (tokenValues * 0.125 + 0.25).reshaped([batch, 1, length, 1])
        let values = (tokenValues * 0.25 - 0.5).reshaped([batch, 1, length, 1])
        let attended = caches[0].updateAndAttend(
            queries: queries,
            keys: keys,
            values: values,
            scale: 1,
            sinks: nil)

        var rowStates: [MLXArray] = []
        rowStates.reserveCapacity(batch)
        for row in 0 ..< batch {
            let evaluation = recurrentState[row]
            let previous = evaluation.inputState(modelLayerIndex: 0)
            let previousConv = previous?.conv ?? MLXArray.zeros([1, 1, 1])
            let previousSSM = previous?.ssm ?? MLXArray.zeros([1, 1, 1, 1])
            let finalToken = tokenValues[row, length - 1].reshaped([1, 1, 1])
            let tokenSum = tokenValues[row].sum().reshaped([1, 1, 1, 1])
            let conv = tanh(previousConv * 0.5 + finalToken * 0.125)
            let ssm = tanh(
                previousSSM * 0.75
                    + tokenSum * 0.0625
                    + conv.reshaped([1, 1, 1, 1]) * 0.25)
            try! evaluation.stage(modelLayerIndex: 0, conv: conv, ssm: ssm)
            rowStates.append(ssm.reshaped([1]))
        }

        let recurrentSignal = broadcast(
            concatenated(rowStates, axis: 0).reshaped([batch, 1, 1]),
            to: [batch, length, 1])
        let attentionSignal = attended.transposed(0, 2, 1, 3)
            .reshaped([batch, length, 1])
        let tokenSignal = tokenValues.reshaped([batch, length, 1])
        let score = sin(
            tokenSignal * 0.71
                + recurrentSignal * 1.31
                + attentionSignal * 0.17)
        return concatenated([score, -score], axis: -1)
    }
}

struct RemoteExactLiveEngineStack {
    let engine: EngineV2
    let model: RemoteExactHybridFixtureModel
}

func makeRemoteExactLiveEngine(
    cache: ExactPrefixCacheV2
) -> RemoteExactLiveEngineStack {
    let model = RemoteExactHybridFixtureModel()
    let kind = CBv2LayerKind(
        attention: .full,
        headDim: 1,
        kvHeads: 1,
        queryHeads: 1)
    let engine = EngineV2(
        model: model,
        layerKinds: [kind],
        backend: CBv2ContiguousKVBackend(
            config: .init(bytesCapacity: 1 << 24, kvDType: .float32)),
        cacheProvider: CBv2LayerCacheBank(layerKinds: [kind]),
        sampler: CBv2GreedySampler(),
        schedulerConfig: .init(
            maxConcurrentRequests: 4,
            maxBatchedTokensPerStep: 64,
            prefillChunkSize: 64,
            maxWaiting: 8,
            enablePrefixCache: true),
        admissionConfig: .init(watermarkFraction: 0, elementBytes: 4),
        prefixCache: cache)
    return RemoteExactLiveEngineStack(engine: engine, model: model)
}
