// Copyright © 2026 Eigen Labs.
// Resolve backend policy and prepare KV resources before engine/cache assembly.

import Foundation
import MLXLLM
import MLX
import MLXLLM
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
        let performanceProfile: ServingPerformanceProfile?
        /// The resolved running-row cap also owns bridge admission accounting
        /// and heartbeat capacity. Never advertise the pre-policy request.
        var effectiveMaxConcurrentRequests: Int { schedulerConfig.maxConcurrentRequests }
        let pagedPoolDType: String?
        /// Actual native KV types shared by live admission, token rates and
        /// checkpoint encoding. Never inferred from weight precision.
        let nativeLayerDTypes: [DType]
        /// Actual immutable storage geometry, captured before type erasure.
        let pagedPoolConfig: PagedKVPoolConfig?
        /// True when this preparation contains a resident physical-page
        /// prefix index. It survives backend type erasure so final assembly
        /// enables the scheduler even when the SSD snapshot L2 is absent.
        let residentPrefixCacheEnabled: Bool
        let hybridPrefixCache: CBv2HybridPrefixCacheConfig?
        let kvQuantization: EngineV2KVQuantizationSelection
        // Resolve storage geometry first. Native authority is issued only after
        // the existing SSD factory has constructed the exact store to bind.
        let glm5NextModel: GLM5NextProtectedModel?
        private let glm5NextBudget: GlobalKVCacheBudget?
        private(set) var glm5NextNative: GLM5NextProtectedResources?

        private let lock = NSLock()
        private let modelIdentity: ObjectIdentifier
        private let requestedMaxConcurrentRequests: Int
        private let installedQwen4Batching: Bool?
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
            performanceProfile: ServingPerformanceProfile? = nil,
            pagedPoolDType: String?,
            nativeLayerDTypes: [DType],
            kvQuantization: EngineV2KVQuantizationSelection = .native,
            residentPrefixCacheEnabled: Bool = false,
            hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil,
            glm5NextModel: GLM5NextProtectedModel? = nil,
            glm5NextBudget: GlobalKVCacheBudget? = nil
        ) {
            self.modelIdentity = ObjectIdentifier(model)
            self.requestedMaxConcurrentRequests = max(1, maxConcurrentRequests)
            self.installedQwen4Batching =
                (model as? any CBv2Qwen4BatchCapabilityConfiguring)?
                .cbv2Qwen4BatchedAttentionEnabled
            self.layerKinds = layerKinds
            self.modelCapabilities = modelCapabilities
            self.backend = backend
            self.caches = caches
            self.kind = kind
            self.fallbackReason = fallbackReason
            self.schedulerConfig = schedulerConfig
            self.performanceProfile = performanceProfile
            self.pagedPoolDType = pagedPoolDType
            self.nativeLayerDTypes = (backend as? PagedKVBackend)?.pool.layerDTypes ?? nativeLayerDTypes
            self.pagedPoolConfig = (backend as? PagedKVBackend)?.pool.config
            self.residentPrefixCacheEnabled = residentPrefixCacheEnabled
            self.hybridPrefixCache = hybridPrefixCache
            self.kvQuantization = kvQuantization
            self.glm5NextModel = glm5NextModel
            self.glm5NextBudget = glm5NextBudget
        }

        /// The GLM step price for the geometry the engine prices at activation,
        /// at the protected model's resolved draft depth; nil for other
        /// backends or once the backend has been consumed.
        func glm5NextStepScratch() throws -> GLM5NextStepScratch? {
            try lock.withLock {
                guard let paged = backend as? PagedKVBackend else { return nil }
                return try EngineV2Factory.glm5NextStepScratch(
                    paged, scheduler: schedulerConfig,
                    maximumDraftTokens: EngineV2Factory.glm5NextDraftTokens(glm5NextModel))
            }
        }

        func consume(
            model: any LanguageModel,
            maxConcurrentRequests: Int,
            completePrefixCache: (any CBv2CompletePrefixCache)? = nil,
            kvBudget: GlobalKVCacheBudget? = nil
        ) throws -> (CBv2KVBackend, [any CBv2AttendingLayerCache]) {
            try lock.withLock {
                guard modelIdentity == ObjectIdentifier(model) else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend model identity changed before assembly")
                }
                guard requestedMaxConcurrentRequests == max(1, maxConcurrentRequests) else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend concurrency changed before assembly")
                }
                guard
                    installedQwen4Batching
                        == (model as? any CBv2Qwen4BatchCapabilityConfiguring)?
                        .cbv2Qwen4BatchedAttentionEnabled
                else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend Qwen4 batching capability changed before assembly"
                    )
                }
                guard let backend, let caches else {
                    throw CBv2KVError.backendIneligible(
                        reason: "prepared backend was already consumed")
                }
                if let glm5NextModel {
                    guard let glm5NextBudget, glm5NextBudget === kvBudget,
                        let paged = backend as? PagedKVBackend,
                        paged.pool.bytesMaterialized == 0, paged.bytesReserved == 0 else {
                        throw EngineV2ProductionError.pagedUnavailable("GLM protected preparation owner changed")
                    }
                    // One attempt only, including failures: SDK resource issuance
                    // cannot be retried with another store or construction scope.
                    self.backend = nil
                    self.caches = nil
                    let native = try GLM5NextProtectedResources(model: glm5NextModel,
                        config: paged.pool.config, budget: glm5NextBudget,
                        completePrefixCache: completePrefixCache)
                    glm5NextNative = native
                    return (native.resources.backend, [])
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
        modelID: String? = nil,
        modelArtifactSHA256: String? = nil,
        constructionPurpose: ConstructionPurpose = .serving,
        automaticallySelectConcurrency: Bool = false,
        performanceQualificationAllowed: Bool = true,
        mtpPerformanceConfiguration: ServingMTPConfiguration? = nil,
        kvBudget: GlobalKVCacheBudget? = nil,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil,
        hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil,
        nativeKVLayerIndices: Set<Int> = [],
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil,
        schedulerPolicy: ((inout CBv2SchedulerConfig) -> Void)? = nil
    ) throws -> ProductionBackendPreparation {
        guard kvBytesCapacity > 0 else {
            throw EngineV2ProductionError.noKVHeadroom
        }
        let cappedCapacity = clampKVBytesCapacity(kvBytesCapacity)
        try configureNativeQwen4Batching(model: model, environment: environment)
        // Flint is qualified only on paged attention. Automatic selection is an
        // explicit paged request: no crash-guard or failure fallback, and any
        // resolution other than paged refuses the load below.
        let kvBackend: EngineV2KVBackendSelection = model is FlintModel && kvBackend == .auto ? .paged : kvBackend

        guard let adapter = ProductionModelAdapter(model: model) else {
            throw EngineV2ProductionError.unsupportedModel(
                String(describing: type(of: model)))
        }
        let layerKinds = adapter.layerKinds
        let modelCapabilities = adapter.modelCapabilities
        let precision = try EngineV2KVQuantizationPolicy.resolve(
            modelType: model is FlintModel ? "flint" : nil, modelID: modelID ?? "", environment: environment)
        let glm5Next = glm5NextTarget(model: model)
        // GLM has no contiguous representation, so automatic selection is paged
        // for every GLM identity. Vetoes below still refuse it instead of degrading.
        var resolvedKind =
            (precision != .native || glm5Next != nil) && kvBackend == .auto
            ? .paged
            : EngineV2KVBackendPolicy.preferredBackend(selection: kvBackend, modelID: modelID)
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

        // Explicit paged ignores the automatic guard.
        if resolvedKind == .paged, kvBackend == .auto,
            EngineV2KVBackendPolicy.crashLoopGuardForcesContiguous(
                record: KVBackendGuardStore.read(environment: environment),
                runningVersion: ProviderCore.version)
        {
            resolvedKind = .contiguous
            fallbackReason = "crash_loop_guard"
        }

        if model is FlintModel, resolvedKind != .paged {
            throw EngineV2ProductionError.pagedUnavailable(
                "Flint requires the paged KV backend; resolved \(resolvedKind.rawValue)"
                    + (fallbackReason.map { " (\($0))" } ?? ""))
        }

        if let glm = glm5Next {
            // Never route GLM's compressed K/V payload through the generic
            // full-attention kernels/probe. Only the target-issued binding can
            // interpret latent K and index/gates/validity V correctly.
            guard resolvedKind == .paged, precision == .native else {
                throw EngineV2ProductionError.pagedUnavailable(
                    "GLM requires its native paged backend and native FP32 KV; resolved "
                        + "\(resolvedKind.rawValue) KV with \(precision.rawValue) precision"
                        + (fallbackReason.map { " (\($0))" } ?? ""))
            }
            if let raw = environment[Self.pagedPoolDTypeEnvKey],
                !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                try Self.pagedPoolDType(environment: environment) != .float32 {
                throw EngineV2ProductionError.pagedUnavailable("GLM payload storage requires float32")
            }
            try pagedPreflightOverride?(layerKinds)
            let selectedContext = maxContextLength ?? (model as? GLM5NextProtectedModel)?.maximumContextLength
                ?? glm.configuration.maxPositionEmbeddings
            let context = try GLM5NextExecutionBound.require(selectedContext,
                modelMaximum: glm.configuration.maxPositionEmbeddings)
            if let protected = model as? GLM5NextProtectedModel, context != protected.maximumContextLength {
                throw GLM5NextExecutionBoundError.backendMismatch(prepared: protected.maximumContextLength, backend: context)
            }
            // Target-only GLM has no checked native completion receipt. It is an
            // explicit benchmark baseline, never a serving engine.
            guard model is GLM5NextProtectedModel || constructionPurpose == .benchmark else {
                throw EngineV2ProductionError.pagedUnavailable(
                    "GLM serving requires the protected embedded-MTP model; target-only is benchmark-only")
            }
            let policy = productionServingPolicy(
                model: model, modelID: modelID, modelArtifactSHA256: modelArtifactSHA256,
                constructionPurpose: constructionPurpose,
                automaticallySelectConcurrency: automaticallySelectConcurrency,
                performanceQualificationAllowed: false, backend: .paged,
                maxContextLength: context, maxConcurrentRequests: maxConcurrentRequests,
                environment: environment, mtpPerformanceConfiguration: mtpPerformanceConfiguration)
            let maximumBuffer = MLX.GPU.deviceInfo().maxBufferSize
            guard maximumBuffer > 0 else { throw EngineV2ProductionError.noKVHeadroom }
            var scheduler = glm5NextServingScheduler(policy.scheduler, context: context)
            let paged = try glm.makeCBv2PagedBackend(
                kvBytesCapacity: cappedCapacity,
                maximumBatchSize: scheduler.maxConcurrentRequests,
                maximumQueryTokens: max(scheduler.maxBatchedTokensPerStep, scheduler.prefillChunkSize,
                    scheduler.soloPrefillStripeTokens ?? 0),
                maximumContextTokens: context,
                maximumScratchBytes: min(cappedCapacity, maximumBuffer),
                segmentBytes: 64 << 20, maximumBufferBytes: maximumBuffer)
            if let protected = model as? GLM5NextProtectedModel {
                scheduler.maxConcurrentRequests = try glm5NextActivatableRows(
                    paged, scheduler: scheduler, layerKinds: layerKinds, context: context,
                    capacityBytes: cappedCapacity, maximumScratchBytes: min(cappedCapacity, maximumBuffer),
                    maximumDraftTokens: glm5NextDraftTokens(protected))
                guard let kvBudget, residentPrefixCache == nil, hybridPrefixCache == nil else {
                    throw EngineV2ProductionError.pagedUnavailable(
                        "GLM protected MTP requires the actual process budget; resident and hybrid prefixes are unsupported")
                }
                return ProductionBackendPreparation(model: model, maxConcurrentRequests: maxConcurrentRequests,
                    layerKinds: layerKinds, modelCapabilities: modelCapabilities,
                    backend: paged, caches: [], kind: .paged, fallbackReason: nil,
                    schedulerConfig: scheduler, pagedPoolDType: "float32",
                    nativeLayerDTypes: Array(repeating: .float32, count: layerKinds.count),
                    glm5NextModel: protected, glm5NextBudget: kvBudget)
            }
            let pagedCaches = paged.makeLayerCaches()
            var mapping: [Int: Int] = [:]
            for (storage, kind) in layerKinds.enumerated() {
                guard mapping.updateValue(storage, forKey: kind.modelLayerIndex ?? storage) == nil else {
                    throw EngineV2ProductionError.pagedUnavailable("GLM cache-layer mapping")
                }
            }
            guard pagedCaches.count == layerKinds.count, let placeholder = pagedCaches.first else {
                throw EngineV2ProductionError.pagedUnavailable("GLM cache-layer count")
            }
            // The cache factory callback cannot throw. Record an undeclared
            // layer and refuse the whole preparation before any cache is used.
            var requestedUndeclaredLayer = false
            let caches = try adapter.newCaches { index, _ in
                guard let storage = mapping[index], storage < pagedCaches.count else {
                    requestedUndeclaredLayer = true
                    return placeholder
                }
                return pagedCaches[storage]
            }
            guard !requestedUndeclaredLayer else {
                throw EngineV2ProductionError.pagedUnavailable("GLM cache-layer mapping")
            }
            return ProductionBackendPreparation(model: model, maxConcurrentRequests: maxConcurrentRequests,
                layerKinds: layerKinds, modelCapabilities: modelCapabilities, backend: paged,
                caches: caches, kind: .paged, fallbackReason: nil, schedulerConfig: scheduler,
                pagedPoolDType: "float32", nativeLayerDTypes: Array(repeating: .float32, count: layerKinds.count))
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
            if precision != .native {
                throw EngineV2KVQuantizationPolicy.Failure.requiresPagedBackend(reason)
            }
            guard EngineV2KVBackendPolicy.degradesPagedFailure(selection: kvBackend)
            else {
                throw EngineV2ProductionError.pagedUnavailable(reason)
            }
            return reason
        }

        // Resolve after each backend decision: an automatic paged fallback
        // cannot retain the paged profile's width or mixed-step geometry.
        func servingPolicy(for kind: EngineV2KVBackendKind) -> (
            CBv2SchedulerConfig, ServingPerformanceProfile?
        ) {
            var resolved = productionServingPolicy(
                model: model, modelID: modelID, modelArtifactSHA256: modelArtifactSHA256,
                constructionPurpose: constructionPurpose,
                automaticallySelectConcurrency: automaticallySelectConcurrency,
                performanceQualificationAllowed: performanceQualificationAllowed
                    && precision == .native,
                backend: kind,
                maxContextLength: maxContextLength, maxConcurrentRequests: maxConcurrentRequests,
                environment: environment, mtpPerformanceConfiguration: mtpPerformanceConfiguration)
            schedulerPolicy?(&resolved.scheduler)
            return resolved
        }

        var nativeKVTypes: CBv2NativeKVTypeProbe.Result?
        var nativeKVProbeFailure: Error?
        /// The recurrent checkpoint bank this backend hosts, carved from its
        /// grant. Paged storage hosts one only when the config opts in.
        func hostedHybridCache(paged: Bool) throws -> CBv2HybridPrefixCacheConfig? {
            guard modelCapabilities.supportsRecurrentCheckpointReuse,
                let hybridPrefixCache, hybridPrefixCache.maximumBytes > 0,
                !hybridPrefixCache.modelID.isEmpty, !hybridPrefixCache.promptContractID.isEmpty,
                !hybridPrefixCache.buildID.isEmpty,
                !paged || hybridPrefixCache.permitsPagedStorage
            else { return nil }
            guard hybridPrefixCache.maximumBytes < cappedCapacity else {
                throw EngineV2ProductionError.noKVHeadroom
            }
            return hybridPrefixCache
        }
        func contiguousPreparation() throws -> ProductionBackendPreparation {
            try EngineV2KVQuantizationPolicy.requireResolvedBackend(
                .contiguous, selection: precision, reason: fallbackReason)
            if let nativeKVProbeFailure { throw nativeKVProbeFailure }
            let observed = try nativeKVTypes ?? probeNativeKVTypes(model: model, adapter: adapter)
            let (schedulerConfig, performanceProfile) = servingPolicy(for: .contiguous)
            let configuredHybridCache = try hostedHybridCache(paged: false)
            let contiguousCapacity = cappedCapacity - (configuredHybridCache?.maximumBytes ?? 0)
            let backend = CBv2ContiguousKVBackend(
                config: CBv2ContiguousBackendConfig(bytesCapacity: contiguousCapacity))
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
                performanceProfile: performanceProfile,
                pagedPoolDType: nil,
                nativeLayerDTypes: observed.layerDTypes,
                hybridPrefixCache: configuredHybridCache)
        }

        if resolvedKind == .paged {
            do {
                if let pagedPreflightOverride {
                    try pagedPreflightOverride(layerKinds)
                } else {
                    try PagedKernelPreflight.run(
                        layerKinds: layerKinds, precision: precision,
                        nativeLayerIndices: nativeKVLayerIndices)
                }
            } catch {
                resolvedKind = .contiguous
                fallbackReason = try degradeOrRefuse("kernel_preflight: \(error)")
            }
        }

        if resolvedKind == .paged {
            do {
                let observed = try probeNativeKVTypes(model: model, adapter: adapter)
                nativeKVTypes = observed
                if let override = environment[Self.pagedPoolDTypeEnvKey],
                    !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !observed.layerDTypes.allSatisfy({ $0 == pagedDType })
                {
                    throw CBv2KVError.backendIneligible(
                        reason:
                            "paged dtype override differs from the loaded model's native KV types")
                }
                pagedDType = observed.layerDTypes.first ?? pagedDType
            } catch {
                if nativeKVTypes == nil { nativeKVProbeFailure = error }
                resolvedKind = .contiguous
                fallbackReason = try degradeOrRefuse("native_kv_probe: \(error)")
            }
        }

        if resolvedKind == .paged, let nativeKVTypes {
            let (schedulerConfig, performanceProfile) = servingPolicy(for: .paged)
            // Quantized reuse requires the typed complete packed checkpoint.
            // Legacy resident blocks have no native-tail/format identity.
            let resolvedResidentPrefix =
                precision == .native && modelCapabilities.supportsPrefixReuse
                ? residentPrefixCache : nil
            // Carve a bank only where the engine hosts one on pages: unquantized
            // storage without a resident page index (`EngineV2.hostsPagedHybridBank`).
            let pagedHybridCache = resolvedResidentPrefix == nil && precision == .native
                ? try hostedHybridCache(paged: true) : nil
            do {
                let paged = try makeSegmentedPagedBackend(
                    admittedGrantBytes: cappedCapacity - (pagedHybridCache?.maximumBytes ?? 0),
                    layerKinds: layerKinds,
                    layerDTypes: nativeKVTypes.layerDTypes,
                    schedulerConfig: schedulerConfig,
                    maxContextLength: maxContextLength,
                    maxBufferLength: MLX.GPU.deviceInfo().maxBufferSize,
                    quantization: precision.configuration,
                    nativeLayerIndices: nativeKVLayerIndices,
                    residentPrefixCache: resolvedResidentPrefix,
                    environment: environment)
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
                    performanceProfile: performanceProfile,
                    pagedPoolDType: Set(nativeKVTypes.layerDTypes).count == 1
                        ? Self.pagedPoolDTypeName(paged.pool.config.dtype) : "mixed",
                    nativeLayerDTypes: nativeKVTypes.layerDTypes,
                    kvQuantization: precision,
                    residentPrefixCacheEnabled: resolvedResidentPrefix != nil,
                    hybridPrefixCache: pagedHybridCache)
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

extension EngineV2Factory {
    /// The GLM engine's admission watermark, shared by the activation row cap
    /// and the engine's own admission configuration.
    static let glm5NextAdmissionWatermarkFraction = AdmissionV2.Config().watermarkFraction

    /// The draft depth `GLM5NextProtectedModel.resolvedMTPConfiguration` serves:
    /// one for serial verification, the rectangular depth otherwise.
    static func glm5NextDraftTokens(_ model: GLM5NextProtectedModel?) -> Int {
        model?.execution.verification.depth ?? GLM5NextMTPVerification.maximumRectangularDepth
    }

    /// One row's query per step, as the engine bounds it at activation: its
    /// prefill chunk or solo stripe, or an MTP verification of 1 + drafts.
    static func glm5NextStepScratch(
        _ paged: PagedKVBackend, scheduler: CBv2SchedulerConfig, maximumDraftTokens: Int
    ) throws -> GLM5NextStepScratch? {
        try paged.glm5NextStepScratch(
            maximumRequests: scheduler.maxConcurrentRequests,
            maximumStepTokens: max(scheduler.maxBatchedTokensPerStep, scheduler.soloPrefillStripeTokens ?? 0),
            maximumRowTokens: max(scheduler.prefillChunkSize, scheduler.soloPrefillStripeTokens ?? 0,
                1 + max(0, maximumDraftTokens)))
    }

    /// The largest running-row cap the engine's activation check admits
    /// (`GLM5NextPagedModelBinding.validateStepEnvelope`), using its split
    /// bound: step setup plus the per-context-token price of min(pool tokens,
    /// rows × context) within the admissible capacity. The native check also
    /// accepts a smaller exact all-rows price it does not expose, so this cap
    /// never exceeds what activation accepts. Below one row the engine reports
    /// its own refusal.
    static func glm5NextActivatableRows(
        _ paged: PagedKVBackend, scheduler: CBv2SchedulerConfig, layerKinds: [CBv2LayerKind],
        context: Int, capacityBytes: Int, maximumScratchBytes: Int, maximumDraftTokens: Int
    ) throws -> Int {
        let tokenBytes = layerKinds.reduce(0) {
            $0 + ($1.headDim + $1.valueHeadDim) * DType.float32.size
        }
        var rows = scheduler.maxConcurrentRequests
        while rows > 1 {
            var candidate = scheduler
            candidate.maxConcurrentRequests = rows
            guard let scratch = try glm5NextStepScratch(
                paged, scheduler: candidate, maximumDraftTokens: maximumDraftTokens)
            else { return rows }
            if glm5NextActivationAdmits(scratch, rows: rows, context: context,
                capacityBytes: capacityBytes, tokenBytes: tokenBytes,
                maximumScratchBytes: maximumScratchBytes,
                watermarkFraction: glm5NextAdmissionWatermarkFraction)
            { break }
            rows -= 1
        }
        return rows
    }

    /// The split-bound arithmetic of the native activation check.
    static func glm5NextActivationAdmits(
        _ scratch: GLM5NextStepScratch, rows: Int, context: Int, capacityBytes: Int,
        tokenBytes: Int, maximumScratchBytes: Int, watermarkFraction: Double
    ) -> Bool {
        guard rows > 0, context > 0, tokenBytes > 0, capacityBytes > 0 else { return false }
        let ceiling = min(
            maximumScratchBytes, capacityBytes - Int(Double(capacityBytes) * watermarkFraction))
        let (history, historyOverflow) = rows.multipliedReportingOverflow(by: context)
        let (variable, variableOverflow) = scratch.bytesPerContextToken
            .multipliedReportingOverflow(by: min(capacityBytes / tokenBytes, history))
        let (required, requiredOverflow) = variable.addingReportingOverflow(scratch.setupBytes)
        return !historyOverflow && !variableOverflow && !requiredOverflow && required <= ceiling
    }
}
