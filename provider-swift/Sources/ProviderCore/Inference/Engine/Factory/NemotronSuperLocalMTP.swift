// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Explicit opt-in text speculation for the unpublished Super local owner,
/// using the checkpoint's embedded head through the SDK's serial-verified
/// assistant. Off unless `DARKBLOOM_NEMOTRON_SUPER_MTP` is exactly `1`; the
/// coordinator must measure it on the full model before any default changes.
/// An owner with speculation installed is text-only: media is refused.
enum NemotronSuperLocalMTP {
    static let enabledKey = "DARKBLOOM_NEMOTRON_SUPER_MTP"
    /// Draft depth `1`…`3`; a value above one is the deep-draft opt-in.
    static let depthKey = "DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH"
    /// Unmeasured allocator/backend scratch admitted with every request's
    /// bounded assistant charge, on top of the SDK's explicit array quotes.
    static let backendScratchBytes = 256 << 20

    enum Failure: Error, Equatable { case invalidDepth, loadQuote }

    /// Header-derived head payload plus loader construction allowance; not a
    /// measured peak. Charged inside the owner's single pending LOAD claim.
    static func loadSupplementBytes(_ quote: NemotronSuperMTPModule.LoadQuote) throws -> Int {
        let (total, overflow) = quote.payloadBytes.addingReportingOverflow(
            quote.constructionBytes)
        guard !overflow, quote.payloadBytes > 0, quote.constructionBytes > 0 else {
            throw Failure.loadQuote
        }
        return total
    }

    struct Setting: Equatable, Sendable {
        let depth: Int

        /// nil keeps the ordinary target-only owner. A malformed depth fails
        /// the load rather than silently changing the measured configuration.
        static func resolve(environment: [String: String]) throws -> Setting? {
            guard environment[enabledKey]?.trimmingCharacters(in: .whitespaces) == "1" else {
                return nil
            }
            guard let raw = environment[depthKey]?.trimmingCharacters(in: .whitespaces) else {
                return Setting(depth: 1)
            }
            guard let depth = Int(raw),
                (1 ... NemotronSuperMTPAssistant.Settings.maximumDepth).contains(depth)
            else { throw Failure.invalidDepth }
            return Setting(depth: depth)
        }
    }

    /// The loaded embedded head and its setting, transferred from the load
    /// transaction to the builder. The engine's drafter keeps it alive until
    /// native retirement.
    struct Head {
        let module: NemotronSuperMTPModule
        let setting: Setting
    }

    /// Engine inputs: the text-only target wrapper, its bound assistant and
    /// the fixed-depth serial verification configuration.
    struct Engine {
        let model: NemotronSuperMTPTextTarget
        let assistant: NemotronSuperMTPAssistant
        let config: CBv2MTPConfig
    }

    static func engine(
        for model: NemotronSuperModel, head: Head, maximumSequenceLength: Int
    ) throws -> Engine {
        let target = NemotronSuperMTPTextTarget(model)
        let depth = head.setting.depth
        let assistant = try target.makeAssistant(
            head: head.module,
            settings: .init(
                maximumDraftTokens: depth, allowsDeepDrafts: depth > 1,
                maximumSequenceLength: maximumSequenceLength,
                backendScratchBytes: backendScratchBytes))
        return Engine(
            model: target, assistant: assistant,
            config: CBv2MTPConfig(
                enabled: true, maxDraftTokens: depth, maxSpeculativeBatch: 1,
                fixedDraftTokens: depth, verificationMode: .serialTarget))
    }
}

extension NemotronSuperLocalMTP {
    enum AssemblyFailure: Error, Equatable { case calibratedPrefill }

    /// Contiguous production build for the speculative text target, mirroring
    /// the contiguous branch of `EngineV2Factory.prepareProductionBackend`. The
    /// shared family dispatch (`ProductionModelAdapter`) and calibrated prefill
    /// bound do not recognize `NemotronSuperMTPTextTarget`, so the scheduler
    /// policy is resolved on the ordinary adapter over the same composite and
    /// the engine is assembled on the target itself.
    static func makeProductionBuild(
        engine: Engine, policyModel: NemotronSuperRecurrentAdapter,
        tokenizer: any MLXLMCommon.Tokenizer, kvBytesCapacity: Int,
        kvBudget: GlobalKVCacheBudget, maxContextLength: Int, environment: [String: String]
    ) throws -> EngineV2Factory.ProductionBuild {
        let target = engine.model
        guard kvBytesCapacity > 0 else { throw EngineV2ProductionError.noKVHeadroom }
        guard let limit = target.calibratedPrefillTokenLimit, limit > 0,
            limit == policyModel.calibratedPrefillTokenLimit
        else { throw AssemblyFailure.calibratedPrefill }
        let modelID = NemotronSuperLocalBinding.modelID
        let precision = try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, modelID: modelID, environment: environment)
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.contiguous, selection: precision)
        let observed = try CBv2NativeKVTypeProbe.run(
            model: CBv2SteppableLanguageModelAdapter(target), layerKinds: target.cbv2LayerKinds,
            caches: target.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) })
        let (schedulerConfig, profile) = EngineV2Factory.productionServingPolicy(
            model: policyModel, modelID: modelID, modelArtifactSHA256: nil,
            constructionPurpose: .serving, automaticallySelectConcurrency: false,
            performanceQualificationAllowed: precision == .native, backend: .contiguous,
            maxContextLength: maxContextLength, maxConcurrentRequests: 1,
            environment: environment)
        guard schedulerConfig.prefillChunkSize <= limit else {
            throw AssemblyFailure.calibratedPrefill
        }
        let prepared = EngineV2Factory.ProductionBackendPreparation(
            model: target, maxConcurrentRequests: 1, layerKinds: target.cbv2LayerKinds,
            modelCapabilities: target.cbv2Capabilities,
            backend: CBv2ContiguousKVBackend(
                config: CBv2ContiguousBackendConfig(
                    bytesCapacity: EngineV2Factory.clampKVBytesCapacity(kvBytesCapacity))),
            caches: try target.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) },
            kind: .contiguous, fallbackReason: nil, schedulerConfig: schedulerConfig,
            performanceProfile: profile, pagedPoolDType: nil,
            nativeLayerDTypes: observed.layerDTypes)
        return try EngineV2Factory.assembleProductionBuild(
            model: target, tokenizer: tokenizer, prefixCache: nil, maxConcurrentRequests: 1,
            mtpDrafter: engine.assistant, mtpConfig: engine.config, preparedBackend: prepared,
            kvBudget: kvBudget)
    }
}
