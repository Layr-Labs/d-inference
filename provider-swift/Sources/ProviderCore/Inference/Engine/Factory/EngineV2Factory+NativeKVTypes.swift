import Foundation
import MLX
import MLXLMCommon

extension EngineV2Factory {
    /// Target storage only. Indexer/recurrent/MTP charges retain their separate owners.
    static func physicalFullKVBytesPerToken(
        layerKinds: [CBv2LayerKind], dtypes: [DType], config: PagedKVPoolConfig
    ) throws -> Int {
        guard layerKinds.count == dtypes.count else {
            throw EngineV2ProductionError.noKVHeadroom
        }
        var total = 0
        for (index, kind) in layerKinds.enumerated() where kind.sharesKVWithLayer == nil {
            guard case .full = kind.attention else { continue }
            let key = PagedKVGroupKey(kind, dtype: dtypes[index], separateWindow: true,
                quantization: config.nativeLayerIndices.contains(index) ? nil : config.quantization)
            let (next, overflow) = total.addingReportingOverflow(try key.bytesPerToken())
            guard !overflow else { throw EngineV2ProductionError.noKVHeadroom }
            total = next
        }
        return total
    }

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
            guard let bytes = kind.kvGeometry?.bytesPerToken(elementBytes: dtype.size)
            else { return Int.max }
            let (value, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return Int.max }
            total = value
        }
        return total
    }

    /// Observe the same loaded target and cache entry point used by serving.
    /// The native helper owns and releases its short request-local state.
    /// The probe is a forward, so it runs once per loaded target, before its first
    /// engine; later constructions (MTP upgrade, recovery) reuse the observation and
    /// run no forward on a target an engine may be serving (see "Multi-token
    /// prediction" in docs/architecture/inference.md).
    static func probeNativeKVTypes(
        model: any LanguageModel, adapter: ProductionModelAdapter
    ) throws -> CBv2NativeKVTypeProbe.Result {
        if let observed = NativeKVTypeObservations.shared.result(
            model: model, layerKinds: adapter.layerKinds)
        {
            return observed
        }
        let caches = try adapter.newCaches { index, kind in
            CBv2LayerCache(layerIndex: index, kind: kind)
        }
        let observed = try CBv2NativeKVTypeProbe.run(
            model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: adapter.layerKinds, caches: caches)
        NativeKVTypeObservations.shared.record(
            observed, model: model, layerKinds: adapter.layerKinds)
        return observed
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

/// Native KV types observed per loaded target. Entries hold the target weakly
/// and match it by identity, so a reloaded target is a new module and is
/// probed again.
private final class NativeKVTypeObservations: @unchecked Sendable {
    static let shared = NativeKVTypeObservations()

    private struct Entry {
        weak var model: AnyObject?
        let layerKinds: [CBv2LayerKind]
        let result: CBv2NativeKVTypeProbe.Result
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func result(
        model: any LanguageModel, layerKinds: [CBv2LayerKind]
    ) -> CBv2NativeKVTypeProbe.Result? {
        lock.withLock {
            entries.first { $0.model === model && $0.layerKinds == layerKinds }?.result
        }
    }

    func record(
        _ result: CBv2NativeKVTypeProbe.Result, model: any LanguageModel,
        layerKinds: [CBv2LayerKind]
    ) {
        lock.withLock {
            entries.removeAll { $0.model == nil || $0.model === model }
            entries.append(Entry(model: model, layerKinds: layerKinds, result: result))
        }
    }
}
