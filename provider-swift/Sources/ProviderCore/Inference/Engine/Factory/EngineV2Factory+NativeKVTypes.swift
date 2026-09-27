import MLX
import MLXLMCommon

extension EngineV2Factory {
    /// The same full-row marginal rate as slot sizing, using the constructed
    /// pool's exact native types. Borrowing rows own no bytes; window storage
    /// remains outside this marginal rate. Invalid arithmetic refuses capacity.
    static func nativeFullKVBytesPerToken(
        layerKinds: [CBv2LayerKind], dtypes: [DType]
    ) -> Int {
        guard layerKinds.count == dtypes.count else { return Int.max }
        var total = 0
        for (kind, dtype) in zip(layerKinds, dtypes) {
            guard [.float16, .bfloat16, .float32].contains(dtype),
                kind.kvHeads > 0, kind.headDim > 0 else { return Int.max }
            guard kind.sharesKVWithLayer == nil, case .full = kind.attention else { continue }
            var bytes = 2
            for factor in [kind.kvHeads, kind.headDim, dtype.size] {
                let (value, overflow) = bytes.multipliedReportingOverflow(by: factor)
                guard !overflow else { return Int.max }
                bytes = value
            }
            let (value, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return Int.max }
            total = value
        }
        return total
    }

    /// Observe the same loaded target and cache entry point used by serving.
    /// The native helper owns and releases its short request-local state.
    static func probeNativeKVTypes(
        model: any LanguageModel, adapter: ProductionModelAdapter
    ) throws -> CBv2NativeKVTypeProbe.Result {
        let caches = try adapter.newCaches { index, kind in
            CBv2LayerCache(layerIndex: index, kind: kind)
        }
        return try CBv2NativeKVTypeProbe.run(
            model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: adapter.layerKinds, caches: caches)
    }

    /// Metadata-only inspection before an engine owns this loaded target.
    /// This does not change model eligibility or construct a serving backend.
    @_spi(Benchmarking)
    public static func inspectNativeKVTypes(
        model: any LanguageModel
    ) throws -> CBv2NativeKVTypeProbe.Result {
        guard let adapter = ProductionModelAdapter(model: model) else {
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
        return try probeNativeKVTypes(model: model, adapter: adapter)
    }
}
