// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Explicit opt-in text speculation for the unpublished Super local owner,
/// using the checkpoint's embedded head through the SDK assistant with exact
/// rectangular (default) or serial target verification. Off unless
/// `DARKBLOOM_NEMOTRON_SUPER_MTP` is exactly `1`; the coordinator must measure
/// it on the full model before any default changes. An owner with speculation
/// installed is text-only: media is refused.
enum NemotronSuperLocalMTP {
    static let enabledKey = "DARKBLOOM_NEMOTRON_SUPER_MTP"
    /// Draft depth `1`…`3`; a value above one is the deep-draft opt-in.
    static let depthKey = "DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH"
    /// `rectangular` (default): one exact captured target window per round;
    /// `serial`: one ordinary target step per column.
    static let verificationKey = "DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION"
    /// Unmeasured allocator/backend scratch admitted with every request's
    /// bounded assistant charge, on top of the SDK's explicit array quotes.
    static let backendScratchBytes = 256 << 20

    enum Failure: Error, Equatable { case invalidDepth, invalidVerification, loadQuote }

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
        typealias Verification = NemotronSuperMTPAssistant.Settings.Verification
        let depth: Int
        var verification: Verification = .rectangularExact

        /// nil keeps the ordinary target-only owner. A malformed depth or
        /// verification fails the load rather than silently changing the
        /// measured configuration.
        static func resolve(environment: [String: String]) throws -> Setting? {
            guard environment[enabledKey]?.trimmingCharacters(in: .whitespaces) == "1" else {
                return nil
            }
            var depth = 1
            if let raw = environment[depthKey]?.trimmingCharacters(in: .whitespaces) {
                guard let value = Int(raw),
                    (1 ... NemotronSuperMTPAssistant.Settings.maximumDepth).contains(value)
                else { throw Failure.invalidDepth }
                depth = value
            }
            let verification: Verification
            switch environment[verificationKey]?.trimmingCharacters(in: .whitespaces) {
            case nil, "rectangular"?: verification = .rectangularExact
            case "serial"?: verification = .serial
            default: throw Failure.invalidVerification
            }
            return Setting(depth: depth, verification: verification)
        }
    }

    /// The loaded embedded head and its setting, transferred from the load
    /// transaction to the builder. The engine's drafter keeps it alive until
    /// native retirement.
    struct Head {
        let module: NemotronSuperMTPModule
        let setting: Setting
    }

    /// Engine inputs: the text-only target wrapper (the capture target for
    /// rectangular verification), its bound assistant and the fixed-depth
    /// configuration with the assistant's verification mode.
    struct Engine {
        let model: NemotronSuperMTPTextTarget
        let assistant: NemotronSuperMTPAssistant
        let config: CBv2MTPConfig
    }

    static func engine(
        for model: NemotronSuperModel, head: Head, maximumSequenceLength: Int
    ) throws -> Engine {
        let verification = head.setting.verification
        let target =
            verification == .rectangularExact
            ? try NemotronSuperMTPCaptureTarget(capturing: model)
            : NemotronSuperMTPTextTarget(model)
        let depth = head.setting.depth
        let assistant = try target.makeAssistant(
            head: head.module,
            settings: .init(
                maximumDraftTokens: depth, allowsDeepDrafts: depth > 1,
                maximumSequenceLength: maximumSequenceLength,
                backendScratchBytes: backendScratchBytes, verification: verification))
        guard let mode = assistant.requiredVerificationMode else {
            throw Failure.invalidVerification
        }
        return Engine(
            model: target, assistant: assistant,
            config: CBv2MTPConfig(
                enabled: true, maxDraftTokens: depth, maxSpeculativeBatch: 1,
                fixedDraftTokens: depth, verificationMode: mode))
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
