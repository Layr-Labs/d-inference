import MLX

/// Build-time observation of the tensors the loaded model actually stores.
/// This includes projection/RoPE promotion and owns only a three-token row.
/// No hooks or probe tensors remain on the serving path.
public enum CBv2NativeKVTypeProbe {
    public enum Phase: String, Sendable { case prefill, decode }

    public struct Observation: Sendable, Equatable {
        public let storageIndex: Int
        public let modelLayerIndex: Int
        public let phase: Phase
        public let keysDType: DType
        public let valuesDType: DType
        public let keysShape: [Int]
        public let valuesShape: [Int]
    }

    public struct Result: Sendable, Equatable {
        /// Includes borrowing layers, whose type is copied from their owner.
        public let layerDTypes: [DType]
        /// Only storage-owning layers produce observations, once per phase.
        public let observations: [Observation]
    }

    /// Supply fresh caches built by the model's normal newCacheV2 entry point.
    /// The caller must budget this short load-time forward like other warmup
    /// work and serialize it with model loading. No active engine may own the
    /// supplied caches. The returned value contains no native array aliases.
    public static func run(
        model: any CBv2SteppableModel, layerKinds: [CBv2LayerKind],
        caches: [any CBv2AttendingLayerCache], token: Int32 = 0
    ) throws -> Result {
        guard token >= 0 else { throw invalid("probe requires fresh matching model caches") }
        let recurrentModel = model as? any CBv2RecurrentSteppableModel
        return try runProbe(layerKinds: layerKinds, caches: caches,
            recurrentModel: recurrentModel,
            prepareTokens: { count, check in
                let tokens = MLXArray(Array(repeating: token, count: count)).reshaped([1, count])
                try check()
                return tokens
            }, forward: { _, _, tokens, transaction in
                // prepareTokens above always supplies the same legacy token root.
                guard let tokens else { throw invalid("model probe has no token root") }
                if let transaction, let recurrentModel {
                    return recurrentModel.forward(
                        tokens: tokens, caches: caches, recurrentState: [transaction])
                }
                return model.forward(tokens: tokens, caches: caches)
            })
    }

    /// Attention-only stage seam for a throwing residual forward. The callback
    /// runs synchronously with the same temporary rows, native error handler,
    /// two-token prefill and one-token decode as the model overload. It must
    /// use the supplied caches and return a root retaining its forward graph.
    ///
    /// The caller owns verified input construction/transport, phase binding,
    /// native admission/deadline and failure cleanup. In particular a later
    /// stage must validate its actual incoming residual dtype, not infer it
    /// from embedding metadata. Neither the callback nor native roots are
    /// retained after this call; Result contains only CPU-owned metadata.
    public static func run(
        layerKinds: [CBv2LayerKind], caches: [any CBv2AttendingLayerCache],
        forward: (Phase, Int, [any CBv2AttendingLayerCache]) throws -> MLXArray
    ) throws -> Result {
        try runProbe(layerKinds: layerKinds, caches: caches,
            recurrentModel: nil, prepareTokens: nil,
            forward: { phase, count, _, _ in try forward(phase, count, caches) })
    }

    /// Both entry points share all row recording, native evaluation, recurrent
    /// transaction handling and result validation. Token preparation remains
    /// before recurrent bind, matching the original model entry's ordering.
    private static func runProbe(
        layerKinds: [CBv2LayerKind], caches: [any CBv2AttendingLayerCache],
        recurrentModel: (any CBv2RecurrentSteppableModel)?,
        prepareTokens: ((Int, () throws -> Void) throws -> MLXArray)?,
        forward: (Phase, Int, MLXArray?, CBv2RecurrentStateEvaluation?) throws -> MLXArray
    ) throws -> Result {
        guard !layerKinds.isEmpty, caches.count == layerKinds.count,
            layerKinds.allSatisfy({ $0.kvHeads > 0 && $0.headDim > 0 }),
            zip(caches, layerKinds).allSatisfy({ $0.0.rows.isEmpty && $0.0.kind == $0.1 })
        else { throw invalid("probe requires fresh matching model caches") }
        let recorders = layerKinds.enumerated().map { index, kind -> RecordingRow? in
            guard kind.sharesKVWithLayer == nil else { return nil }
            return RecordingRow(index: index, kind: kind)
        }
        for index in layerKinds.indices {
            caches[index].setRows(recorders[index].map { [$0] } ?? [])
        }
        defer { for cache in caches { cache.setRows([]) } }

        let recurrent = try recurrentModel?.recurrentStateSpec.map(CBv2RecurrentRequestState.init(spec:))
        defer { try? recurrent?.release() }
        var observations: [Observation] = []
        for phase: Phase in [.prefill, .decode] {
            let count = phase == .prefill ? 2 : 1
            for case let row? in recorders { row.begin(phase: phase, count: count) }
            try withError { error in
                let tokens = try prepareTokens?(count, { try error.check() })
                let transaction = try recurrent?.bind()
                defer { try? transaction?.rollback() }
                let output = try forward(phase, count, tokens, transaction)
                try error.check()
                // Validate before allocating/evaluating the forward's graph.
                // Shapes and dtypes are graph metadata, not tensor readbacks.
                for case let row? in recorders { observations.append(try row.observation()) }
                let recurrentRoots = try transaction?.evaluate() ?? []
                let roots = recorders.compactMap { $0 }.flatMap { $0.cbv2InnerState() }
                eval([output] + recurrentRoots + roots)
                try error.check()
                try transaction?.commit()
            }
        }
        var types = Array<DType?>(repeating: nil, count: layerKinds.count)
        for observation in observations {
            let index = observation.storageIndex
            if let previous = types[index], previous != observation.keysDType {
                throw invalid("layer \(index) changes KV dtype between prefill and decode")
            }
            types[index] = observation.keysDType
        }
        for (index, kind) in layerKinds.enumerated() {
            guard let source = kind.sharesKVWithLayer else { continue }
            guard types.indices.contains(source), layerKinds[source].sharesKVWithLayer == nil,
                layerKinds[source].kvHeads == kind.kvHeads,
                layerKinds[source].headDim == kind.headDim,
                layerKinds[source].attention == kind.attention
            else { throw invalid("layer \(index) has an invalid KV owner") }
            types[index] = types[source]
        }
        guard types.allSatisfy({ $0 != nil }) else { throw invalid("probe did not observe every KV owner") }
        return Result(layerDTypes: types.map { $0! }, observations: observations)
    }

    private static func invalid(_ reason: String) -> CBv2KVError {
        .backendIneligible(reason: "native KV probe: " + reason)
    }

    /// The normal attention dispatcher calls this row after all model-side
    /// transforms. A full three-token buffer is also exact for the short
    /// window probe: visibility still comes from the layer's attention kind.
    private final class RecordingRow: CBv2SequenceKV, CBv2InnerStateProviding {
        let index: Int
        let kind: CBv2LayerKind
        let storage: CBv2FullSequenceKV
        private var phase = Phase.prefill
        private var count = 0
        private var observed: Observation?
        private var violation: String?

        init(index: Int, kind: CBv2LayerKind) {
            self.index = index
            self.kind = kind
            storage = CBv2FullSequenceKV(promptLength: 2, maxLength: 3,
                                        kvHeads: kind.kvHeads, headDim: kind.headDim)
        }

        func begin(phase: Phase, count: Int) {
            self.phase = phase
            self.count = count
            observed = nil
            violation = nil
        }

        func update(keys: MLXArray, values: MLXArray) -> (MLXArray, MLXArray) {
            guard observed == nil, violation == nil else {
                violation = "layer \(index) updated more than once during \(phase.rawValue)"
                return (keys, values)
            }
            let shape = [1, kind.kvHeads, count, kind.headDim]
            guard keys.shape == shape, values.shape == shape,
                keys.dtype == values.dtype,
                [.float16, .bfloat16, .float32].contains(keys.dtype)
            else {
                violation = "layer \(index) has unsupported or asymmetric native K/V: \(keys.dtype)/\(values.dtype), \(keys.shape)/\(values.shape)"
                return (keys, values)
            }
            observed = Observation(
                storageIndex: index, modelLayerIndex: kind.modelLayerIndex ?? index,
                phase: phase, keysDType: keys.dtype, valuesDType: values.dtype,
                keysShape: keys.shape, valuesShape: values.shape)
            return storage.update(keys: keys, values: values)
        }

        func observation() throws -> Observation {
            if let violation { throw invalid(violation) }
            guard let observed else { throw invalid("layer \(index) did not update during \(phase.rawValue)") }
            return observed
        }

        var absoluteOffset: Int { storage.absoluteOffset }
        var retainedCount: Int { storage.retainedCount }
        var byteCount: Int { storage.byteCount }
        func snapshot() -> (keys: MLXArray, values: MLXArray, offset: Int) { storage.snapshot() }
        func rollback(_ n: Int) { storage.rollback(n) }
        func cbv2InnerState() -> [MLXArray] { storage.cbv2InnerState() }
    }
}
