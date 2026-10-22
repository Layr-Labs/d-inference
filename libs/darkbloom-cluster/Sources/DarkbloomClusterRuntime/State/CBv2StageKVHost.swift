import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Which KV storage a cluster stage's attention rows live in. Paged is the
/// product's default backend (`PagedKVBackend`, segmented pool); contiguous is
/// the earlier per-request storage, kept as a diagnosis switch only.
public enum ClusterStageKVBackendKind: String, Sendable, Equatable {
    case paged
    case contiguous

    public static let environmentName = "DARKBLOOM_CLUSTER_KV_BACKEND"

    /// Paged unless the diagnosis switch names contiguous. Anything else stops
    /// the load by name; it never silently falls back.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        try Self.named(environment) ?? .paged
    }

    /// The backend the launch named, nil when it named none. Anything but
    /// paged or contiguous stops the load by name.
    public static func named(_ environment: [String: String]) throws -> Self? {
        guard let raw = environment[environmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        guard let value = Self(rawValue: raw.lowercased()) else {
            throw ProbeError("Unknown \(environmentName)=\(raw); only paged or contiguous can be declared")
        }
        return value
    }

    /// A stage's backend when the launch named none: PAGED, for every stage
    /// and mode (owner rule 2026-10-22: paged attention only for KV, never
    /// contiguous), MTP stages included; a named backend (the diagnosis
    /// switch) always wins. Both ranks derive the same value.
    ///
    /// History of the earlier interim default (contiguous for one-request
    /// MTP stages), kept for the measurements it records:
    ///
    /// Interim (2026-10-12): with the head, paged storage is still slower than
    /// contiguous, on the pair and on one Mac alone. 9B at 30K, same binary:
    /// verify windows (columns batched, each column still reads the whole
    /// context) decode at 88 vs 107 tok/s on the pair (95 vs 133 on one Mac),
    /// and prefill chunks re-gather all earlier pages (first token 9.3 vs
    /// 7.1 s). `batchLanes` > 1 only occurs in pipeline mode, which has no
    /// head. Paged returns for MTP stages once both gaps close.
    ///
    /// 2026-10-13 (items 23-25: prefill mirror, multi-query verify kernel,
    /// host frontier): still kept. The prefill gap is nearly closed (first
    /// token within 1-5 %), but paged MTP decode stays 7-34 % below
    /// contiguous on the pair (9B 30K 87 vs 104 tok/s, 27B 30K 30 vs 45).
    /// The multi-query verify window costs ~2.5x the contiguous window's
    /// attention (attention only, 9B geometry at 30K: 10.6 vs 4.2 ms per
    /// 4 layers, 17.6 ms before item 24).
    public static func resolved(environment: [String: String], speculative: Bool, batchLanes: Int) throws -> Self {
        try Self.named(environment) ?? .paged
    }

    /// Extra load-agreement fields: both ranks must store and attend the same
    /// way. Contiguous keeps the agreement bytes it always had.
    var loadAgreementFields: [String] { self == .contiguous ? [] : ["cluster-stage-kv-v1", rawValue] }
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
/// a ceiling for `lanes` requests of `maximumTokensPerRequest` tokens, not an
/// allocation: pages are reserved per request at its own maximum length.
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

    static let segmentBytes = 64 << 20

    /// Builds the host for a dense or routed-expert Qwen 3.5 stage, a Gemma 4
    /// stage (its sliding layers as page rings, as the single-Mac product
    /// pages `gemma-4-26b-qat-4bit`) or a Nemotron 3.5 stage (its attention
    /// layers; its Mamba state stays per request). Other families keep their
    /// own per-request contiguous geometry.
    init(model: any LanguageModel, kind: ClusterStageKVBackendKind, lanes: Int,
         maximumTokensPerRequest: Int, maximumChunkTokens: Int) throws {
        guard (1...8).contains(lanes), maximumTokensPerRequest > 0, maximumTokensPerRequest <= ClusterWorkerLimits.contextTokens,
              maximumChunkTokens > 0 else {
            throw ProbeError("Stage KV host needs 1...8 lanes and a bounded request length")
        }
        if let gemma = model as? Gemma4LayerStageModel {
            // Every layer owns its rows (no shared keys/values), keyed by the
            // stage's own storage index; a sliding layer's row is a page ring
            // of its window plus one speculative span (`PagedKVPool.ringPageCount`).
            let geometry = try gemma.layerStageRequestGeometry(maximumTokens: maximumTokensPerRequest)
            // A paged request holds whole pages: a ring a page past the window,
            // a full layer rounded up to a page (`CBv2PagedKVResidency`).
            let perRequest = kind == .paged
                ? max(geometry.kvCapacityBytes, try Self.pagedRequestBytes(kinds: geometry.kinds, dtype: geometry.kvDType,
                    maximumTokens: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens))
                : geometry.kvCapacityBytes
            let capacity = try QwenLongPrefillCheckedBytes.sum([
                QwenLongPrefillCheckedBytes.product([perRequest, lanes]), Self.segmentBytes])
            let caches: [any CBv2AttendingLayerCache]
            switch kind {
            case .paged:
                let paged = try Self.pagedBackend(kinds: geometry.kinds, dtype: geometry.kvDType,
                    capacity: capacity, maximumTokensPerRequest: maximumTokensPerRequest,
                    maximumChunkTokens: maximumChunkTokens)
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
            self.kind = kind; layerKinds = geometry.kinds
            self.caches = caches; bank = CBv2LayerCacheBank(caches: caches)
            kvDType = geometry.kvDType; self.lanes = lanes; self.maximumTokensPerRequest = maximumTokensPerRequest
            capacityBytes = capacity
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
        let perRequest = try Self.pageRoundedRequestBytes(kvShapes: kinds.map { ($0.kvHeads, $0.headDim) },
            maximumTokens: maximumTokensPerRequest, dtypeSize: dtype.size)
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
                maximumTokensPerRequest: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens)
            let storage = paged.makeLayerCaches()
            // Item 23: a one-request host's prompt chunks attend a transient
            // contiguous mirror instead of re-gathering the history per chunk.
            // The mirror is one more copy of the prefilling request's KV,
            // which `perRequest` bounds; batch lanes keep the gather. (Qwen
            // only: qualified there.)
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
        self.capacityBytes = capacity
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

    /// The segmented paged pool every hosted stage takes its pages from: one
    /// group per attention geometry, a sliding layer's row a ring.
    static func pagedBackend(kinds: [CBv2LayerKind], dtype: DType, capacity: Int, maximumTokensPerRequest: Int,
                             maximumChunkTokens: Int) throws -> PagedKVBackend {
        do {
            return try PagedKVBackend(layerKinds: kinds, config: PagedKVPoolConfig(
                capacityBytes: capacity, dtype: dtype,
                maxPrefillChunk: maximumChunkTokens,
                nominalMaxSequenceLength: maximumTokensPerRequest,
                maxBufferLength: GPU.deviceInfo().maxBufferSize,
                segmentSizeBytes: Self.segmentBytes,
                layerDTypes: Array(repeating: dtype, count: kinds.count)), slabCommitment: .atFirstAdmission)
        } catch {
            throw ProbeError("Paged KV backend is ineligible for this stage: \(error)")
        }
    }

    /// One request's keys and values on the paged pool at `maximumTokens`:
    /// each layer's whole pages as the pool reserves them (a sliding layer's
    /// at most its ring).
    static func pagedRequestBytes(kinds: [CBv2LayerKind], dtype: DType, maximumTokens: Int,
                                  maximumChunkTokens: Int) throws -> Int {
        let residency = CBv2PagedKVResidency(config: PagedKVPoolConfig(capacityBytes: 1, dtype: dtype,
            maxPrefillChunk: maximumChunkTokens, nominalMaxSequenceLength: maximumTokens,
            segmentSizeBytes: Self.segmentBytes))
        return try QwenLongPrefillCheckedBytes.sum(try kinds.map { kind in
            guard let rows = residency.residentRows(layer: kind, tokens: maximumTokens) else {
                throw ProbeError("Paged request bytes overflow")
            }
            return try QwenLongPrefillCheckedBytes.product([rows, kind.kvHeads, kind.headDim + kind.valueHeadDim,
                dtype.size])
        })
    }

    /// One line for whoever launched the worker: sizes only.
    func report(_ purpose: String) {
        log("darkbloom-stage-kv-v1 backend=\(kind.rawValue) purpose=\(purpose) lanes=\(lanes)"
            + " max_tokens=\(maximumTokensPerRequest) capacity=\(capacityBytes) reserved=\(backend.bytesReserved)"
            + " in_use=\(backend.bytesInUse)")
    }
}

extension CBv2StageKVHost {
    /// One request's keys and values in this stage's attention layers at
    /// `maximumTokens`, page-rounded as the pool reserves them. The resident
    /// allowance charges more than this plus one segment for every request
    /// (`CBv2StageKVAllowanceTests`).
    static func pageRoundedRequestBytes(kvShapes: [(kvHeads: Int, headDim: Int)], maximumTokens: Int,
                                        dtypeSize: Int) throws -> Int {
        guard maximumTokens > 0, dtypeSize > 0 else { throw ProbeError("Stage KV request bytes need a positive length") }
        let page = CBv2PagedDefaults.pageSize
        let tokens = (maximumTokens + page - 1) / page * page
        return try QwenLongPrefillCheckedBytes.sum(try kvShapes.map {
            try QwenLongPrefillCheckedBytes.product([tokens, $0.kvHeads, $0.headDim, dtypeSize, 2])
        })
    }

    /// True for the stage models whose request geometry takes a host (so
    /// their KV is paged unless the diagnosis switch names contiguous): the
    /// Qwen 3.5 and Gemma 4 stages, and a one-lane Nemotron 3.5 stage (its
    /// batch lanes are not built: `decodeBatch` has no Nemotron forward).
    static func supports(_ model: any LanguageModel, lanes: Int) -> Bool {
        if model is Gemma4LayerStageModel { return true }
        if model is NemotronH35Model { return lanes == 1 }
        return (model is Qwen35TextModel || model is Qwen35Model) && !(model is any LayerStageFrameForwarding)
            && !(model is NemotronHModel)
    }

    /// Installs a host on a loaded stage. A stage of another family keeps its
    /// per-request contiguous storage and gets none (returns nil).
    @discardableResult
    static func install(on stage: LoadedQwenLayerStage, kind: ClusterStageKVBackendKind, lanes: Int,
                        maximumTokensPerRequest: Int, maximumChunkTokens: Int) throws -> CBv2StageKVHost? {
        guard stage.kvHost.host == nil else { throw ProbeError("Stage KV host is already installed") }
        guard supports(stage.model, lanes: lanes) else { return nil }
        let host = try CBv2StageKVHost(model: stage.model, kind: kind, lanes: lanes,
            maximumTokensPerRequest: maximumTokensPerRequest, maximumChunkTokens: maximumChunkTokens)
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
