// Copyright © 2026 Eigen Labs.
// Resolve backend policy and prepare KV resources before engine/cache assembly.

import Foundation
import MLX
import MLXLMCommon

extension EngineV2Factory {
    /// Resolved resources with a one-time transfer to the same model/concurrency.
    final class ProductionBackendPreparation {
        let layerKinds: [CBv2LayerKind]
        let modelCapabilities: CBv2ModelCapabilities
        let kind: EngineV2KVBackendKind
        let fallbackReason: String?
        /// Shared with final assembly; pool sizing must match the engine's chunks.
        let schedulerConfig: CBv2SchedulerConfig
        let pagedPoolDType: String?
        /// Immutable table read from the constructed pool for process admission.
        let pagedLayerDTypes: [DType]?
        /// Actual immutable storage geometry, captured before type erasure.
        let pagedPoolConfig: PagedKVPoolConfig?
        /// True when this preparation contains a resident physical-page
        /// prefix index. It survives backend type erasure so final assembly
        /// enables the scheduler even when the SSD snapshot L2 is absent.
        let residentPrefixCacheEnabled: Bool
        let hybridPrefixCache: CBv2HybridPrefixCacheConfig?

        private let lock = NSLock()
        private let modelIdentity: ObjectIdentifier
        private let maxConcurrentRequests: Int
        private var backend: CBv2KVBackend?
        private var caches: [any CBv2AttendingLayerCache]?

        init(
            model: any LanguageModel,
            maxConcurrentRequests: Int,
            layerKinds: [CBv2LayerKind],
            modelCapabilities: CBv2ModelCapabilities,
            backend: CBv2KVBackend,
            caches: [any CBv2AttendingLayerCache],
            kind: EngineV2KVBackendKind,
            fallbackReason: String?,
            schedulerConfig: CBv2SchedulerConfig,
            pagedPoolDType: String?,
            residentPrefixCacheEnabled: Bool = false,
            hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil
        ) {
            self.modelIdentity = ObjectIdentifier(model)
            self.maxConcurrentRequests = max(1, maxConcurrentRequests)
            self.layerKinds = layerKinds
            self.modelCapabilities = modelCapabilities
            self.backend = backend
            self.caches = caches
            self.kind = kind
            self.fallbackReason = fallbackReason
            self.schedulerConfig = schedulerConfig
            self.pagedPoolDType = pagedPoolDType
            self.pagedLayerDTypes = (backend as? PagedKVBackend)?.pool.layerDTypes
            self.pagedPoolConfig = (backend as? PagedKVBackend)?.pool.config
            self.residentPrefixCacheEnabled = residentPrefixCacheEnabled
            self.hybridPrefixCache = hybridPrefixCache
        }

        func consume(
            model: any LanguageModel,
            maxConcurrentRequests: Int
        ) throws -> (CBv2KVBackend, [any CBv2AttendingLayerCache]) {
            try lock.withLock {
                guard modelIdentity == ObjectIdentifier(model) else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend model identity changed before assembly")
                }
                guard self.maxConcurrentRequests == max(1, maxConcurrentRequests) else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend concurrency changed before assembly")
                }
                guard let backend, let caches else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend was already consumed")
                }
                self.backend = nil
                self.caches = nil
                return (backend, caches)
            }
        }
    }

    /// Resolve the backend before constructing a reusable prefix cache. Policy
    /// vetoes may override explicit paged intent; construction failures may not.
    static func prepareProductionBackend(
        model: any LanguageModel,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil,
        hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil,
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
    ) throws -> ProductionBackendPreparation {
        guard kvBytesCapacity > 0 else {
            throw EngineV2ProductionError.noKVHeadroom
        }
        var cappedCapacity = clampKVBytesCapacity(kvBytesCapacity)

        guard let adapter = ProductionModelAdapter(model: model) else {
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
        let layerKinds = adapter.layerKinds
        let modelCapabilities = adapter.modelCapabilities
        var resolvedKind: EngineV2KVBackendKind
        switch kvBackend {
        case .contiguous: resolvedKind = .contiguous
        case .paged: resolvedKind = .paged
        // Preserve the rollout default until the full model gate is complete.
        case .auto: resolvedKind = .contiguous
        }
        var fallbackReason: String?
        // Preserve precedence: model capability, operator kill switch, then
        // the version-scoped automatic crash guard. The first veto owns the reason.
        if resolvedKind == .paged, !modelCapabilities.supportsPagedKV {
            resolvedKind = .contiguous
            fallbackReason = "model_capability"
        }
        if resolvedKind == .paged,
            EngineV2KVBackendPolicy.killSwitchDisabled(environment: environment)
        {
            resolvedKind = .contiguous
            fallbackReason = "kill_switch"
        }

        // Dormant while auto chooses contiguous; explicit paged ignores this guard.
        if resolvedKind == .paged, kvBackend == .auto,
            EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                record: KVBackendGuardStore.read(environment: environment),
                runningVersion: ProviderCore.version)
        {
            resolvedKind = .contiguous
            fallbackReason = "crash_loop_guard"
        }

        // Parse dtype before kernel preflight, and only for a resolved paged build.
        var pagedDType = DType.float16
        if resolvedKind == .paged {
            do {
                pagedDType = try Self.pagedPoolDType(environment: environment)
            } catch let error as EngineV2ProductionError {
                guard case .invalidPagedPoolDType(let raw) = error,
                    EngineV2KVBackendPolicy.degradesPagedFailure(selection: kvBackend)
                else { throw error }
                resolvedKind = .contiguous
                fallbackReason = "invalid_dtype: \(raw)"
            }
        }

        // Unlike policy overrides, paged failures must reject explicit requests.
        func degradeOrRefuse(_ reason: String) throws -> String {
            guard EngineV2KVBackendPolicy.degradesPagedFailure(selection: kvBackend)
            else {
                throw EngineV2ProductionError.pagedUnavailable(reason)
            }
            return reason
        }

        let schedulerConfig = productionSchedulerConfig(
            maxConcurrentRequests: maxConcurrentRequests,
            model: model,
            environment: environment)

        let configuredHybridCache: CBv2HybridPrefixCacheConfig?
        if modelCapabilities.supportsRecurrentCheckpointReuse,
            let hybridPrefixCache, hybridPrefixCache.maximumBytes > 0,
            !hybridPrefixCache.modelID.isEmpty, !hybridPrefixCache.promptContractID.isEmpty,
            !hybridPrefixCache.buildID.isEmpty
        {
            guard hybridPrefixCache.maximumBytes < cappedCapacity else {
                throw EngineV2ProductionError.noKVHeadroom
            }
            configuredHybridCache = hybridPrefixCache
            cappedCapacity -= hybridPrefixCache.maximumBytes
        } else {
            configuredHybridCache = nil
        }
        func contiguousPreparation() throws -> ProductionBackendPreparation {
            let backend = CBv2ContiguousKVBackend(
                config: CBv2ContiguousBackendConfig(bytesCapacity: cappedCapacity))
            let caches = try adapter.newCaches { index, kind in
                CBv2LayerCache(layerIndex: index, kind: kind)
            }
            return ProductionBackendPreparation(
                model: model,
                maxConcurrentRequests: maxConcurrentRequests,
                layerKinds: layerKinds,
                modelCapabilities: modelCapabilities,
                backend: backend,
                caches: caches,
                kind: .contiguous,
                fallbackReason: fallbackReason,
                schedulerConfig: schedulerConfig,
                pagedPoolDType: nil,
                hybridPrefixCache: configuredHybridCache)
        }

        var nativeKVTypes: CBv2NativeKVTypeProbe.Result?
        if resolvedKind == .paged {
            do {
                if let pagedPreflightOverride {
                    try pagedPreflightOverride(layerKinds)
                } else {
                    try PagedKernelPreflight.run(layerKinds: layerKinds)
                }
            } catch {
                resolvedKind = .contiguous
                fallbackReason = try degradeOrRefuse("kernel_preflight: \(error)")
            }
        }

        if resolvedKind == .paged {
            do {
                let observed = try probeNativeKVTypes(model: model, adapter: adapter)
                if let override = environment[Self.pagedPoolDTypeEnvKey],
                    !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !observed.layerDTypes.allSatisfy({ $0 == pagedDType }) {
                    throw CBv2KVError.backendIneligible(
                        reason: "paged dtype override differs from the loaded model's native KV types")
                }
                nativeKVTypes = observed
                pagedDType = observed.layerDTypes.first ?? pagedDType
            } catch {
                resolvedKind = .contiguous
                fallbackReason = try degradeOrRefuse("native_kv_probe: \(error)")
            }
        }

        if resolvedKind == .paged, let nativeKVTypes {
            do {
                let paged = try makeSegmentedPagedBackend(
                    admittedGrantBytes: cappedCapacity,
                    layerKinds: layerKinds,
                    layerDTypes: nativeKVTypes.layerDTypes,
                    schedulerConfig: schedulerConfig,
                    maxContextLength: maxContextLength,
                    maxBufferLength: MLX.GPU.deviceInfo().maxBufferSize,
                    residentPrefixCache: modelCapabilities.supportsPrefixReuse
                        ? residentPrefixCache : nil)
                let pagedCaches = paged.makeLayerCaches()
                // Hybrid models number caches by model layer, while paged storage
                // is dense over attending layers. Convert before indexing the pool.
                var storageForModelIndex: [Int: Int] = [:]
                for (storage, kind) in layerKinds.enumerated() {
                    storageForModelIndex[kind.modelLayerIndex ?? storage] = storage
                }
                let caches = try adapter.newCaches { index, _ in
                    guard let storage = storageForModelIndex[index],
                        storage < pagedCaches.count
                    else {
                        preconditionFailure(
                            "paged cache storage mapping missing model layer \(index) "
                                + "(\(pagedCaches.count) storage slots)")
                    }
                    return pagedCaches[storage]
                }
                return ProductionBackendPreparation(
                    model: model,
                    maxConcurrentRequests: maxConcurrentRequests,
                    layerKinds: layerKinds,
                    modelCapabilities: modelCapabilities,
                    backend: paged,
                    caches: caches,
                    kind: .paged,
                    fallbackReason: nil,
                    schedulerConfig: schedulerConfig,
                    pagedPoolDType: Set(nativeKVTypes.layerDTypes).count == 1
                        ? Self.pagedPoolDTypeName(paged.pool.config.dtype) : "mixed",
                    residentPrefixCacheEnabled:
                        modelCapabilities.supportsPrefixReuse
                            && residentPrefixCache != nil)
            } catch let error as CBv2KVError {
                switch error {
                case .backendIneligible(let reason):
                    fallbackReason = try degradeOrRefuse("ineligible: \(reason)")
                case .capacityExhausted(let needed, let available):
                    fallbackReason = try degradeOrRefuse(
                        "pool_construction_capacity: needed \(needed), "
                            + "available \(available)")
                }
            }
        }
        return try contiguousPreparation()
    }
}
