import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Which KV storage a cluster stage's attention rows live in: the product's
/// paged pool (`PagedKVBackend`, segmented), as on one Mac. Contiguous
/// per-request storage remains only as the in-process reference the tests
/// compare paged storage against (and run without GPU kernels); no launch can
/// select it.
public enum ClusterStageKVBackendKind: String, Sendable, Equatable {
    case paged
    case contiguous

    public static let environmentName = "DARKBLOOM_CLUSTER_KV_BACKEND"

    /// Paged, for every stage and mode (owner rule 2026-10-22: paged
    /// attention only for KV). The former diagnosis switch may still name
    /// paged; contiguous or anything else stops the load by name, never
    /// silently. Both ranks derive the same value.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let raw = environment[environmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != Self.paged.rawValue else { return .paged }
        guard raw.lowercased() != Self.contiguous.rawValue else {
            throw ProbeError("\(environmentName)=contiguous was removed: cluster stage KV is paged only, as on one Mac")
        }
        throw ProbeError("Unknown \(environmentName)=\(raw); only paged can be declared")
    }

    /// Extra load-agreement fields: both ranks must store and attend the same
    /// way. Contiguous keeps the agreement bytes it always had.
    var loadAgreementFields: [String] { self == .contiguous ? [] : ["cluster-stage-kv-v1", rawValue] }
}

extension PagedKVQuantizationSelection {
    /// This rank's live precision: the value its owner resolved from the
    /// provider's own settings (`engine_v2_kv_quantization`, per model, or
    /// `DARKBLOOM_CBV2_KV_QUANTIZATION`, exactly as main resolves them) and
    /// put in the launch environment; native when the launch names none.
    /// Anything else stops the load by name.
    static func clusterLive(_ environment: [String: String]) throws -> Self {
        try PagedKVQuantizationPolicy.parseSelection(environment[PagedKVQuantizationPolicy.environmentKey] ?? "")
    }

    /// Bound into the load agreement beside the stage KV backend, so both
    /// ranks store their rows at one precision and a mismatched peer stops
    /// before either stage is read. Native adds nothing: every native load
    /// keeps the agreement bytes it always had.
    var loadAgreementFields: [String] {
        guard let configuration else { return [] }
        return ["cluster-stage-kv-quantization-v1", rawValue, configuration.identity]
    }

    /// Stops a load whose path cannot keep packed rows, by name: the path's
    /// storage is not the product's paged pool (main's own refusal), or it
    /// moves request state between owners as native arrays.
    func requireNative(_ reason: String, paged: Bool = true) throws {
        guard self != .native else { return }
        guard paged else { throw PagedKVQuantizationPolicy.Failure.requiresPagedBackend(reason) }
        throw ProbeError("Live \(rawValue) KV cannot serve \(reason); select native live precision")
    }
}

/// Held by every copy of one `LoadedQwenLayerStage`: the stage's KV host once
/// its owner installed one, nil before that and after release.
final class CBv2StageKVHostBox {
    var host: CBv2StageKVHost?
}

/// One loaded stage's shared KV storage: the backend every request of this
/// stage takes its rows from, the layer caches the forward attends through,
/// and the single bank that binds rows to those caches. One per loaded stage
/// model, alive until the model is released; never shared between stages.
///
/// The paged pool is the product's segmented pool (64 MB segments that grow
/// with admitted demand, `PagedKVBackend` + `PagedLayerCache`). Its capacity is
/// a ceiling for `lanes` requests of `maximumTokensPerRequest` tokens (up to
/// the wire's longest context, for a row that serves its native one), not an
/// allocation: pages are reserved per request, at its own length or as it
/// grows (`CBv2OwnedRequestState.growReservation`).
/// Every native mutation happens on the owner's serial executor, which is the
/// pool's thread-affinity contract.
final class CBv2StageKVHost {
    let kind: ClusterStageKVBackendKind
    let layerKinds: [CBv2LayerKind]
    let backend: any CBv2KVBackend
    /// In the model's compact attention order (`newCacheV2`), the order the
    /// request geometry and its rows use.
    let caches: [any CBv2AttendingLayerCache]
    let bank: CBv2LayerCacheBank
    let kvDType: DType
    let lanes: Int
    let maximumTokensPerRequest: Int
    let capacityBytes: Int
    /// The live precision the pool stores its rows at (main's policy, carried
    /// by the launch). Native keeps every step and byte the host always had.
    let quantization: PagedKVQuantizationSelection
    /// One request's pages at `maximumTokensPerRequest`, at the pool's real
    /// bytes per token (`pagedRequestBytes`); `capacityBytes` is `lanes` of
    /// these and one segment.
    let requestPageBytes: Int
    /// Packed storage only: one request's peak original-precision rows (its
    /// recent tokens and a prompt chunk) and their transfer scratch, outside
    /// the pages, as main's admission prices them
    /// (`PagedKVPool.admissionStorageConfig`); 0 for native storage.
    let nativeRecentBytesPerRequest: Int

    static let segmentBytes = PagedKVBackend.servingSegmentBytes

    /// Builds the host for a dense or routed-expert Qwen 3.5 stage, a Gemma 4
    /// stage (its sliding layers as page rings, as the single-Mac product
    /// pages `gemma-4-26b-qat-4bit`) or a Nemotron 3.5 stage (its attention
    /// layers; its Mamba state stays per request). Other families keep their
    /// own per-request contiguous geometry. A packed `quantization` takes
    /// main's kernel preflight first, and a layout main does not pack refuses
    /// the load as main refuses it.
    init(model: any LanguageModel, kind: ClusterStageKVBackendKind, lanes: Int,
         maximumTokensPerRequest: Int, maximumChunkTokens: Int,
         quantization: PagedKVQuantizationSelection = .native) throws {
        guard (1...8).contains(lanes), maximumTokensPerRequest > 0, maximumTokensPerRequest <= ClusterWorkerLimits.wireContextTokens,
              maximumChunkTokens > 0 else {
            throw ProbeError("Stage KV host needs 1...8 lanes and a bounded request length")
        }
        if kind == .contiguous { try quantization.requireNative("contiguous stage KV", paged: false) }
        if let gemma = model as? Gemma4LayerStageModel {
            // Every layer owns its rows (no shared keys/values), keyed by the
            // stage's own storage index; a sliding layer's row is a page ring
            // of its window plus one speculative span (`PagedKVPool.ringPageCount`).
            let geometry = try gemma.layerStageRequestGeometry(maximumTokens: maximumTokensPerRequest)
            // A paged request holds whole pages: a ring a page past the window,
            // a full layer rounded up to a page (`CBv2PagedKVResidency`).
            // Native pages never undercut the request's own rows; packed
            // pages are smaller by design.
            let pages = try Self.pagedRequestBytes(kinds: geometry.kinds, dtype: geometry.kvDType,
                quantization: quantization, maximumTokens: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens)
            let perRequest = kind == .contiguous ? geometry.kvCapacityBytes
                : quantization == .native ? max(geometry.kvCapacityBytes, pages) : pages
            let capacity = try QwenLongPrefillCheckedBytes.sum([
                QwenLongPrefillCheckedBytes.product([perRequest, lanes]), Self.segmentBytes])
            let backend: any CBv2KVBackend
            let caches: [any CBv2AttendingLayerCache]
            switch kind {
            case .paged:
                let paged = try Self.pagedBackend(kinds: geometry.kinds, dtype: geometry.kvDType,
                    capacity: capacity, maximumTokensPerRequest: maximumTokensPerRequest,
                    maximumChunkTokens: maximumChunkTokens, quantization: quantization)
                caches = paged.makeLayerCaches()
                backend = paged
            case .contiguous:
                caches = geometry.kinds.enumerated().map { CBv2LayerCache(layerIndex: $0.offset, kind: $0.element) }
                backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: capacity, kvDType: geometry.kvDType))
            }
            guard caches.count == geometry.kinds.count,
                  zip(caches, geometry.kinds).allSatisfy({ $0.kind == $1 && $0.rows.isEmpty }) else {
                throw ProbeError("Stage KV host caches differ from the Gemma stage's layers")
            }
            self.kind = kind; layerKinds = geometry.kinds; self.backend = backend
            self.caches = caches; bank = CBv2LayerCacheBank(caches: caches)
            kvDType = geometry.kvDType; self.lanes = lanes; self.maximumTokensPerRequest = maximumTokensPerRequest
            capacityBytes = capacity; self.quantization = quantization; requestPageBytes = perRequest
            nativeRecentBytesPerRequest = try Self.nativeRecentBytes(backend)
            return
        }
        let kinds: [CBv2LayerKind]
        if let model = model as? Qwen35TextModel { kinds = model.cbv2LayerKinds }
        else if let model = model as? Qwen35Model { kinds = model.cbv2LayerKinds }
        else if let model = model as? NemotronH35Model { kinds = model.cbv2LayerKinds }
        else { throw ProbeError("Stage KV host supports the Qwen 3.5, Gemma 4 and Nemotron 3.5 stage models only") }
        guard !kinds.isEmpty,
              let types = (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
              types.count == kinds.count, let dtype = types.first,
              [.float16, .bfloat16, .float32].contains(dtype), types.allSatisfy({ $0 == dtype }) else {
            throw ProbeError("Stage KV host requires known, uniform native attention KV dtypes")
        }
        for kind in kinds {
            guard case .full = kind.attention, kind.sharesKVWithLayer == nil, kind.kvHeads > 0, kind.headDim > 0,
                  kind.valueHeadDim == kind.headDim else {
                throw ProbeError("Stage KV host supports full-attention layers without KV sharing only")
            }
        }
        let perRequest = try Self.pagedRequestBytes(kinds: kinds, dtype: dtype, quantization: quantization,
            maximumTokens: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens)
        let capacity = try QwenLongPrefillCheckedBytes.sum([
            QwenLongPrefillCheckedBytes.product([perRequest, lanes]), Self.segmentBytes])
        var storageForModelLayer: [Int: Int] = [:]
        for (storage, kind) in kinds.enumerated() {
            guard let layer = kind.modelLayerIndex, storageForModelLayer.updateValue(storage, forKey: layer) == nil else {
                throw ProbeError("Stage KV host attention layers lack a unique model index")
            }
        }
        func compact(_ make: (Int, CBv2LayerKind) throws -> any CBv2AttendingLayerCache) throws -> [any CBv2AttendingLayerCache] {
            if let model = model as? Qwen35TextModel { return try model.newCacheV2(makeLayerCache: make) }
            if let model = model as? Qwen35Model { return try model.newCacheV2(makeLayerCache: make) }
            if let model = model as? NemotronH35Model { return try model.newCacheV2(makeLayerCache: make) }
            throw ProbeError("Stage KV host supports the Qwen 3.5, Gemma 4 and Nemotron 3.5 stage models only")
        }
        let backend: any CBv2KVBackend
        let caches: [any CBv2AttendingLayerCache]
        switch kind {
        case .paged:
            let paged = try Self.pagedBackend(kinds: kinds, dtype: dtype, capacity: capacity,
                maximumTokensPerRequest: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens,
                quantization: quantization)
            let storage = paged.makeLayerCaches()
            // Item 23: a one-request host's prompt chunks attend a transient
            // contiguous mirror instead of re-gathering the history per chunk.
            // The mirror is one more copy of the prefilling request's KV,
            // which `perRequest` bounds; batch lanes keep the gather. (Qwen
            // only: qualified there. A packed layer keeps its own path.)
            if lanes == 1, !(model is NemotronH35Model) {
                for cache in storage { cache.prefillMirrorAllowed = true }
            }
            caches = try compact { layer, _ in
                guard let index = storageForModelLayer[layer], storage.indices.contains(index) else {
                    throw ProbeError("Paged cache storage mapping misses model layer \(layer)")
                }
                return storage[index]
            }
            backend = paged
        case .contiguous:
            backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: capacity, kvDType: dtype))
            caches = try compact { CBv2LayerCache(layerIndex: $0, kind: $1) }
        }
        guard caches.count == kinds.count,
              zip(caches, kinds).allSatisfy({ $0.kind == $1 && $0.rows.isEmpty }) else {
            throw ProbeError("Stage KV host caches differ from the model's attention layers")
        }
        self.kind = kind; self.layerKinds = kinds; self.backend = backend; self.caches = caches
        self.bank = CBv2LayerCacheBank(caches: caches)
        self.kvDType = dtype; self.lanes = lanes; self.maximumTokensPerRequest = maximumTokensPerRequest
        self.capacityBytes = capacity; self.quantization = quantization; self.requestPageBytes = perRequest
        self.nativeRecentBytesPerRequest = try Self.nativeRecentBytes(backend)
    }

    /// True when the cache at compact position `index` is this host's.
    func owns(_ cache: any CBv2AttendingLayerCache, at index: Int) -> Bool {
        caches.indices.contains(index) && caches[index] === cache
    }

    /// The storage index a cache reports (`layerIndex`): the model layer for
    /// contiguous caches, the dense attention-storage index for paged ones.
    func expectedLayerIndex(compact index: Int) -> Int? {
        kind == .paged ? index : layerKinds[index].modelLayerIndex
    }

    /// Nothing reserved, nothing bound: every request of this stage retired.
    var isDrained: Bool {
        backend.bytesReserved == 0 && backend.bytesInUse == 0 && caches.allSatisfy { $0.rows.isEmpty }
    }

    /// The segmented paged pool every hosted stage takes its pages from, built
    /// as the provider builds its own (`PagedKVBackend.segmented`): one group
    /// per attention geometry, a sliding layer's row a ring. Packed storage
    /// first passes main's kernel preflight in this process; a packed pool
    /// that cannot be built or probed refuses the load with main's refusal.
    static func pagedBackend(kinds: [CBv2LayerKind], dtype: DType, capacity: Int, maximumTokensPerRequest: Int,
                             maximumChunkTokens: Int,
                             quantization: PagedKVQuantizationSelection = .native) throws -> PagedKVBackend {
        if let configuration = quantization.configuration {
            do {
                try PagedKernelSmokePlan(layerKinds: kinds, quantization: configuration).runInProcess()
            } catch {
                throw PagedKVQuantizationPolicy.Failure.requiresPagedBackend("kernel_preflight: \(error)")
            }
        }
        do {
            return try PagedKVBackend.segmented(admittedGrantBytes: capacity, layerKinds: kinds,
                layerDTypes: Array(repeating: dtype, count: kinds.count), maxPrefillChunk: maximumChunkTokens,
                nominalMaxSequenceLength: maximumTokensPerRequest, maxBufferLength: GPU.deviceInfo().maxBufferSize,
                quantization: quantization.configuration)
        } catch {
            guard quantization != .native else { throw ProbeError("Paged KV backend is ineligible for this stage: \(error)") }
            switch error as? CBv2KVError {
            case .backendIneligible(let reason)?:
                throw PagedKVQuantizationPolicy.Failure.requiresPagedBackend("ineligible: \(reason)")
            case .capacityExhausted(let needed, let available)?:
                throw PagedKVQuantizationPolicy.Failure.requiresPagedBackend(
                    "pool_construction_capacity: needed \(needed), available \(available)")
            case nil:
                throw PagedKVQuantizationPolicy.Failure.requiresPagedBackend("ineligible: \(error)")
            }
        }
    }

    /// One request's keys and values on the paged pool at `maximumTokens`:
    /// each owning layer's whole pages as the pool reserves them (a sliding
    /// layer's at most its ring), at its storage key's real bytes per token
    /// (`PagedKVGroupKey.bytesPerToken`: packed rows and their FP32 scales and
    /// offsets for a quantized layer). Native storage prices exactly as before.
    static func pagedRequestBytes(kinds: [CBv2LayerKind], dtype: DType,
                                  quantization: PagedKVQuantizationSelection = .native,
                                  maximumTokens: Int, maximumChunkTokens: Int) throws -> Int {
        guard maximumTokens > 0, maximumChunkTokens > 0 else {
            throw ProbeError("Stage KV request bytes need a positive length")
        }
        let residency = CBv2PagedKVResidency(config: PagedKVPoolConfig(capacityBytes: 1, dtype: dtype,
            maxPrefillChunk: maximumChunkTokens, nominalMaxSequenceLength: maximumTokens,
            segmentSizeBytes: Self.segmentBytes))
        let keys = PagedKVBackend.segmentedGroupKeys(layerKinds: kinds,
            layerDTypes: Array(repeating: dtype, count: kinds.count), quantization: quantization.configuration)
        return try QwenLongPrefillCheckedBytes.sum(try zip(kinds, keys).compactMap { kind, key in
            guard kind.sharesKVWithLayer == nil else { return nil }
            guard let rows = residency.residentRows(layer: kind, tokens: maximumTokens) else {
                throw ProbeError("Paged request bytes overflow")
            }
            return try QwenLongPrefillCheckedBytes.product([rows, key.bytesPerToken()])
        })
    }

    /// A packed pool's per-request peak outside its pages (see
    /// `nativeRecentBytesPerRequest`); 0 for every other backend.
    static func nativeRecentBytes(_ backend: any CBv2KVBackend) throws -> Int {
        guard let paged = backend as? PagedKVBackend, paged.usesQuantizedStorage else { return 0 }
        return try paged.pool.admissionStorageConfig(.init(watermarkFraction: 0)).minimumRequestTransientBytes
    }

    /// Speculative windows open on this host's packed rows, counted by their
    /// requests (`CBv2OwnedRequestState`): a step's completion is pool-wide,
    /// so none may complete under another request's open window.
    var openPackedWindows = 0

    /// After a step's graph was built and before it is evaluated: a write the
    /// packed pool refused fails the step here, as main's engine checks before
    /// evaluating (`PagedKVBackend.checkOwnedStepWrites`). Native storage keeps
    /// the cluster's step path exactly as it was.
    func checkStepWrites() throws {
        guard quantization != .native, let paged = backend as? PagedKVBackend else { return }
        try paged.checkOwnedStepWrites()
    }

    /// After each confirmed step of this host's rows (a speculative window
    /// once, after its settlement): packed storage completes the step as
    /// main's engine does (`PagedKVBackend.finishOwnedStep`).
    func finishStep() throws {
        guard quantization != .native, let paged = backend as? PagedKVBackend else { return }
        guard openPackedWindows == 0 else {
            throw ProbeError("A packed stage step would complete under another request's open speculative window")
        }
        try paged.finishOwnedStep()
    }

    /// After a failed request's rows were released and its streams drained.
    func discardFailedStep() {
        guard quantization != .native, let paged = backend as? PagedKVBackend else { return }
        paged.discardFailedOwnedStepAfterSynchronization()
    }

    /// Counter reads only, on the owner executor. The materialized pool metric
    /// is actual committed backing, not its physical grant or reservation.
    var batchMemory: StageBatchObservation.Memory {
        .init(backend: kind.rawValue, capacity: backend.bytesCapacity,
              reserved: backend.bytesReserved, inUse: backend.bytesInUse,
              materialized: (backend as? PagedKVBackend)?.pool.bytesMaterialized,
              boundRows: caches.reduce(0) { $0 + $1.rows.count }, drained: isDrained)
    }

    /// One line for whoever launched the worker: sizes only.
    func report(_ purpose: String) {
        log("darkbloom-stage-kv-v1 backend=\(kind.rawValue) purpose=\(purpose) lanes=\(lanes)"
            + " max_tokens=\(maximumTokensPerRequest) capacity=\(capacityBytes) reserved=\(backend.bytesReserved)"
            + " in_use=\(backend.bytesInUse) kv_quantization=\(quantization.rawValue)"
            + (quantization == .native ? "" : " request_pages=\(requestPageBytes) native_recent=\(nativeRecentBytesPerRequest)"))
    }
}

extension CBv2StageKVHost {
    /// True for the stage models whose request geometry takes a host (so
    /// their KV is paged, at the launch's live precision): the
    /// Qwen 3.5, Gemma 4 and Nemotron 3.5 stages. Each lane owns its
    /// attention rows and recurrent transaction; the stage decoder dispatches
    /// the model's native batch entry point.
    static func supports(_ model: any LanguageModel, lanes: Int) -> Bool {
        if model is Gemma4LayerStageModel { return true }
        if model is NemotronH35Model { return (1...8).contains(lanes) }
        return (model is Qwen35TextModel || model is Qwen35Model) && !(model is any LayerStageFrameForwarding)
            && !(model is NemotronHModel)
    }

    /// Installs a host on a loaded stage. A stage of another family keeps its
    /// per-request contiguous storage and gets none (returns nil); it cannot
    /// keep packed rows, so a quantized precision refuses it, as main refuses
    /// quantized KV on storage that is not paged.
    @discardableResult
    static func install(on stage: LoadedQwenLayerStage, kind: ClusterStageKVBackendKind, lanes: Int,
                        maximumTokensPerRequest: Int, maximumChunkTokens: Int,
                        quantization: PagedKVQuantizationSelection = .native) throws -> CBv2StageKVHost? {
        guard stage.kvHost.host == nil else { throw ProbeError("Stage KV host is already installed") }
        guard supports(stage.model, lanes: lanes) else {
            try quantization.requireNative("\(type(of: stage.model)) stage storage", paged: false)
            return nil
        }
        let host = try CBv2StageKVHost(model: stage.model, kind: kind, lanes: lanes,
            maximumTokensPerRequest: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens,
            quantization: quantization)
        stage.kvHost.host = host
        host.report("install stage=\(stage.stageIndex)")
        return host
    }

    /// Removes the host before its stage is released, so its pool goes with
    /// the model. Returns false when a request still held pages or rows
    /// (the caller treats that as a failed release).
    @discardableResult
    static func uninstall(from stage: LoadedQwenLayerStage?) -> Bool {
        guard let stage, let host = stage.kvHost.host else { return true }
        let drained = host.isDrained
        host.bank.releaseBoundRows()
        stage.kvHost.host = nil
        return drained
    }
}
