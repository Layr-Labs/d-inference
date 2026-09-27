// Copyright © 2026 Eigen Labs.
// Production assembly over an already-loaded serving model. Backend resources
// are prepared before cache construction so reuse follows the backend served.

import Foundation
import MLXLMCommon

/// Construction failures reported by the factory's refusal telemetry.
enum EngineV2ProductionError: Error, CustomStringConvertible {
    case unsupportedModel(String)
    case noKVHeadroom
    case pagedUnavailable(String)
    case invalidPagedPoolDType(String)

    var description: String {
        switch self {
        case .unsupportedModel(let type):
            return "engine_v2: model type \(type) has no CBv2 adapter"
        case .noKVHeadroom:
            return "engine_v2: no KV byte headroom under the unified-memory cap"
        case .pagedUnavailable(let reason):
            return "engine_v2: paged KV backend explicitly requested but "
                + "unavailable — \(reason)"
        case .invalidPagedPoolDType(let raw):
            return "engine_v2: \(EngineV2Factory.pagedPoolDTypeEnvKey)=\"\(raw)\" is not a "
                + "recognized paged page dtype (expected float16 or float32)"
        }
    }
}

extension EngineV2Factory {
    /// Build the same production engine used by serving and benchmark callers.
    /// Use `makeProductionBuild` when the resolved backend metadata is needed.
    public static func makeProductionEngine(
        model: any LanguageModel,
        modelID: String? = nil,
        tokenizer: any MLXLMCommon.Tokenizer,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBudget: GlobalKVCacheBudget? = nil,
        activationReserveBytes: UInt64? = nil,
        prefixCache: (any CBv2PrefixCache)? = nil,
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil,
        hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil,
        completePrefixCache: (any CBv2CompletePrefixCache)? = nil,
        mtpDrafter: (any CBv2MTPDrafter)? = nil,
        mtpConfig: CBv2MTPConfig = CBv2MTPConfig(),
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any CBv2Engine {
        try makeProductionBuild(
            model: model,
            modelID: modelID,
            tokenizer: tokenizer,
            kvBytesCapacity: kvBytesCapacity,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBudget: kvBudget,
            activationReserveBytes: activationReserveBytes,
            prefixCache: prefixCache,
            residentPrefixCache: residentPrefixCache,
            hybridPrefixCache: hybridPrefixCache,
            completePrefixCache: completePrefixCache,
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig,
            kvBackend: kvBackend,
            maxContextLength: maxContextLength,
            environment: environment
        ).engine
    }

    /// The engine and resolved backend metadata used for admission and telemetry.
    public struct ProductionBuild {
        public let engine: any CBv2Engine
        /// Concrete engine residency, including MTP expansion.
        public let fixedRequestBytes: Int
        public let kvBackendKind: EngineV2KVBackendKind
        /// Policy override or automatic degradation; explicit paged failures throw.
        public let kvBackendFallbackReason: String?
        /// Dtype read from the constructed pool; nil for contiguous storage.
        public let pagedPoolDType: String?
        /// The engine's native Admission owns its complete process charge.
        public let usesProcessMemoryOwner: Bool

        /// Stable spelling consumed by benchmark artifact readers.
        public var resolvedKVBackendDescriptor: String {
            kvBackendFallbackReason.map { "\(kvBackendKind.rawValue) (fallback: \($0))" }
                ?? kvBackendKind.rawValue
        }

        public init(
            engine: any CBv2Engine,
            fixedRequestBytes: Int,
            kvBackendKind: EngineV2KVBackendKind,
            kvBackendFallbackReason: String?,
            pagedPoolDType: String? = nil,
            usesProcessMemoryOwner: Bool = false
        ) {
            self.engine = engine
            self.fixedRequestBytes = fixedRequestBytes
            self.kvBackendKind = kvBackendKind
            self.kvBackendFallbackReason = kvBackendFallbackReason
            self.pagedPoolDType = pagedPoolDType
            self.usesProcessMemoryOwner = usesProcessMemoryOwner
        }
    }

    /// Prepare backend resources, then assemble the engine. Slot loading may call
    /// these phases separately to construct a prefix cache for the resolved backend.
    public static func makeProductionBuild(
        model: any LanguageModel,
        modelID: String? = nil,
        tokenizer: any MLXLMCommon.Tokenizer,
        kvBytesCapacity: Int,
        maxConcurrentRequests: Int,
        kvBudget: GlobalKVCacheBudget? = nil,
        activationReserveBytes: UInt64? = nil,
        prefixCache: (any CBv2PrefixCache)? = nil,
        residentPrefixCache: CBv2PagedPrefixCacheConfig? = nil,
        hybridPrefixCache: CBv2HybridPrefixCacheConfig? = nil,
        completePrefixCache: (any CBv2CompletePrefixCache)? = nil,
        mtpDrafter: (any CBv2MTPDrafter)? = nil,
        mtpConfig: CBv2MTPConfig = CBv2MTPConfig(),
        kvBackend: EngineV2KVBackendSelection = .auto,
        maxContextLength: Int? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        pagedPreflightOverride: (([CBv2LayerKind]) throws -> Void)? = nil
    ) throws -> ProductionBuild {
        let preparedBackend = try prepareProductionBackend(
            model: model,
            modelID: modelID,
            kvBytesCapacity: kvBytesCapacity,
            maxConcurrentRequests: maxConcurrentRequests,
            kvBackend: kvBackend,
            maxContextLength: maxContextLength,
            environment: environment,
            residentPrefixCache: residentPrefixCache,
            hybridPrefixCache: mtpDrafter == nil || mtpDrafter is any CBv2MTPPrefixCheckpointDrafter
                ? hybridPrefixCache : nil,
            pagedPreflightOverride: pagedPreflightOverride)
        return try assembleProductionBuild(
            model: model,
            tokenizer: tokenizer,
            prefixCache: prefixCache,
            completePrefixCache: completePrefixCache,
            maxConcurrentRequests: maxConcurrentRequests,
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig,
            preparedBackend: preparedBackend,
            kvBudget: kvBudget)
    }

    /// Consume the prepared resources exactly once. Preserve the scheduler config
    /// used to size the pool; only cache enablement is decided during assembly.
    static func assembleProductionBuild(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        prefixCache: (any CBv2PrefixCache)?,
        completePrefixCache: (any CBv2CompletePrefixCache)? = nil,
        maxConcurrentRequests: Int,
        mtpDrafter: (any CBv2MTPDrafter)?,
        mtpConfig: CBv2MTPConfig,
        preparedBackend: ProductionBackendPreparation,
        kvBudget: GlobalKVCacheBudget? = nil
    ) throws -> ProductionBuild {
        let (backend, caches) = try preparedBackend.consume(
            model: model,
            maxConcurrentRequests: maxConcurrentRequests)
        if let violation = EngineV2.backendCapabilityViolation(
            capabilities: preparedBackend.modelCapabilities, backend: backend) {
            throw EngineV2ProductionError.pagedUnavailable(violation)
        }
        let effectivePrefixCache = preparedBackend.modelCapabilities.supportsPrefixReuse
            ? prefixCache : nil
        var schedulerConfig = preparedBackend.schedulerConfig
        schedulerConfig.enablePrefixCache =
            effectivePrefixCache != nil || preparedBackend.residentPrefixCacheEnabled
                || preparedBackend.hybridPrefixCache != nil
                || completePrefixCache != nil
        let processOwner: EngineProcessMemoryOwner?
        if preparedBackend.kind == .paged, let kvBudget {
            // Binding after any slab/request allocation would lose the required
            // reserve-before-allocation boundary. Contiguous keeps its existing
            // bridge claim until its actual backing coverage is implemented.
            guard let paged = backend as? PagedKVBackend,
                paged.pool.config.segmentSizeBytes != nil,
                paged.pool.config.layerDTypes != nil,
                paged.pool.bytesMaterialized == 0, paged.bytesReserved == 0
            else {
                throw EngineV2ProductionError.pagedUnavailable(
                    "process memory ownership requires an empty segmented paged backend")
            }
            processOwner = kvBudget.makeEngineMemoryOwner()
        } else {
            processOwner = nil
        }
        let engine = EngineV2(
            model: CBv2SteppableLanguageModelAdapter(model),
            layerKinds: preparedBackend.layerKinds,
            backend: backend,
            cacheProvider: CBv2LayerCacheBank(caches: caches),
            sampler: CBv2DefaultSampler(),
            detokenizerFactory: CBv2TextDetokenizerFactory(tokenizer: tokenizer),
            schedulerConfig: schedulerConfig,
            loopConfig: CBv2EngineLoopConfig(
                useLegacyRequestTimeout: Self.legacyRequestTimeoutEnabled()),
            prefixCache: effectivePrefixCache,
            hybridPrefixCache: preparedBackend.hybridPrefixCache,
            completePrefixCache: completePrefixCache,
            mtpDrafter: mtpDrafter,
            mtpConfig: mtpConfig,
            processMemoryOwner: processOwner)
        return ProductionBuild(
            engine: engine,
            fixedRequestBytes: engine.resolvedFixedBytesPerRequest,
            kvBackendKind: preparedBackend.kind,
            kvBackendFallbackReason: preparedBackend.fallbackReason,
            pagedPoolDType: preparedBackend.pagedPoolDType,
            usesProcessMemoryOwner: processOwner != nil)
    }
}
