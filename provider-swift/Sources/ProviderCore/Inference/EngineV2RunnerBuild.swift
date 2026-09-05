// Copyright © 2026 Eigen Labs.
//
// The runner boundary, provider side (Darkbloom runner contract §3, §5, §9,
// §12c). ONE construction path for every family.
//
// A runner is one model family behind the CBv2 engine, with a static
// manifest, and it lives in the fork (`MLXRunners`). Darkbloom is one of its
// two consumers; `bench-worker` is the other. The split the contract draws
// is:
//
//   * the RUNNER supplies the model, its tokenizer, its layer kinds, its
//     per-layer caches, its capabilities, and its drafter;
//   * the CALLER supplies POLICY, and every piece of it crosses on
//     `EngineBuild`: which KV backend won the selection ladder, the byte
//     capacity that survived re-slicing and the physical clamp, the
//     scheduler config, the loop config, the SSD prefix cache, the decoder,
//     the MTP config, and the environment.
//
// `Runner.adopt` is what lets the provider take that path without loading
// anything twice: the slot lifecycle owns a resident `ModelContainer`, and
// `adopt` derives the serving model, the layer kinds, the decoders and the
// head provenance from the module the container already holds plus
// `config.json`. A runner that could only `load` would read a checkpoint the
// process is already holding — on a 113 GB model, a second copy in unified
// memory.
//
// Nothing here decides policy. `EngineV2SlotFactory` and
// `EngineV2Factory.prepareProductionBackend` still own the KV-backend
// selection, the slot vetoes, the kill switch, the crash-loop guard, the
// paged physical-capacity plan, the prefix-cache construction gate, and the
// degrade-or-refuse ladder; this file is where their verdict is handed to a
// runner. The result keeps the shape the rest of the provider reads
// (`EngineV2Factory.ProductionBuild`), so the bridge, the shared KV ledger,
// the heartbeat clamp, and the `engine_v2_refusal` telemetry path are
// unchanged.

import Foundation
import MLXLMCommon
import MLXRunners

/// The provider's resolved policy for one slot, in Darkbloom's vocabulary.
/// Mapped onto `EngineBuild` by `EngineV2Factory.makeRunnerBuild`; every
/// field is a decision some earlier layer already took.
struct EngineV2RunnerPolicy {
    /// The RESOLVED backend — after the selection ladder, the slot vetoes,
    /// the kill switch, the crash-loop guard, and any degrade.
    var kvBackendKind: EngineV2KVBackendKind
    /// Non-nil only when a paged selection degraded to contiguous; carried
    /// through to `ProductionBuild` for the INFO `engine_v2_kv_backend`
    /// telemetry.
    var kvBackendFallbackReason: String?
    /// The slot's live-KV grant, already re-sliced against co-resident slots,
    /// clamped to physical memory, and — on a resolved paged build — reduced
    /// to what `PagedKVPhysicalCapacityPolicy` planned.
    var kvBytesCapacity: Int
    var schedulerConfig: CBv2SchedulerConfig
    var loopConfig: CBv2EngineLoopConfig
    /// The encrypted SSD tier, or nil when the construction gate declined
    /// it. Non-nil ⇒ the engine runs with `enablePrefixCache: true`.
    var prefixCache: (any CBv2PrefixCache)?
    var mtpConfig: CBv2MTPConfig
    var environment: [String: String]

    init(
        kvBackendKind: EngineV2KVBackendKind,
        kvBackendFallbackReason: String? = nil,
        kvBytesCapacity: Int,
        schedulerConfig: CBv2SchedulerConfig,
        loopConfig: CBv2EngineLoopConfig,
        prefixCache: (any CBv2PrefixCache)? = nil,
        mtpConfig: CBv2MTPConfig = CBv2MTPConfig(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.kvBackendKind = kvBackendKind
        self.kvBackendFallbackReason = kvBackendFallbackReason
        self.kvBytesCapacity = kvBytesCapacity
        self.schedulerConfig = schedulerConfig
        self.loopConfig = loopConfig
        self.prefixCache = prefixCache
        self.mtpConfig = mtpConfig
        self.environment = environment
    }
}

extension EngineV2Factory {

    /// Resources the caller injects at load time, keyed by the name the
    /// RUNNER declares (contract §12c item 1). The manifest does not list
    /// resource names in schema v1, so the name is read off the runner type
    /// that owns it — never spelled again here.
    ///
    /// Qwen 3.8 Flash-Next is the one family that needs this today: its
    /// n-gram PLE table is 29.8 GiB, is never held as model parameters, and
    /// its rows are read from the shard DIRECTORY the offline transform
    /// writes — which for a provider checkpoint is the model directory
    /// itself. The fork's loader drops the `ngram_embedding` shard tensors
    /// before the model materializes them (`WeightNameFiltering`), so they
    /// stay on disk for this reader. A path to a single file is refused by
    /// the reader, by name; a family that does not use the resource ignores
    /// it.
    static func runnerResources(modelDirectory: URL) -> RunnerResources {
        var resources = RunnerResources()
        // `isDirectory: true` explicitly: the reader refuses a file by name,
        // and a URL built from a path alone does not carry the distinction
        // until the path exists on disk.
        resources[Qwen4ExpRunner.ngramRowSourceResource] =
            URL(fileURLWithPath: modelDirectory.path, isDirectory: true) as NSURL
        return resources
    }

    /// What the caller wants honored. The runner never downloads and never
    /// reads the network.
    ///
    /// `preloadedDrafter` is the slot's already-resident assistant: Darkbloom
    /// keeps it across engine rebuilds, so handing it in is the difference
    /// between binding a module and reading its tensors a second time.
    static func runnerLoadOptions(
        modelDirectory: URL,
        drafterDirectory: URL? = nil,
        kvBytesCapacity: Int,
        maxSequenceLength: Int,
        preloadedDrafter: (any CBv2MTPDrafter)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RunnerLoadOptions {
        RunnerLoadOptions(
            drafterDirectory: drafterDirectory,
            kvBytesCapacity: kvBytesCapacity,
            maxSequenceLength: maxSequenceLength,
            environment: environment,
            resources: runnerResources(modelDirectory: modelDirectory),
            preloadedDrafter: preloadedDrafter)
    }

    /// Resolve the family through the registry and adopt the module the
    /// provider already has resident. This is THE construction entry point:
    /// no family is named here, and no weights are read.
    ///
    /// Multimodal checkpoints get RETRIES, and none of them is a family
    /// test here: a wrapper the family's runner does not serve is offered
    /// again as the text tower the caller can produce. Each candidate is
    /// tried in order and only `unexpectedModel` moves on to the next, so a
    /// real failure inside a candidate surfaces as itself.
    ///
    /// This exists because two fork runners accept the LLM-side module but
    /// not the multimodal wrapper the provider actually loads for those
    /// checkpoints — see the note in the PR body. A runner that serves its
    /// own wrapper accepts on the first call and never reaches a retry.
    static func adoptRunner(
        model: any LanguageModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelDirectory: URL,
        configuration: ModelConfiguration? = nil,
        options: RunnerLoadOptions,
        textTowerCandidates: [() throws -> any LanguageModel] = []
    ) throws -> any Runner {
        let runnerType = try RunnerRegistry.shared.resolve(
            modelType: RunnerCheckpoint.modelType(at: modelDirectory))
        let resolvedConfiguration =
            configuration ?? ModelConfiguration(directory: modelDirectory)
        func adopt(_ module: any LanguageModel) throws -> any Runner {
            try runnerType.adopt(
                model: module,
                tokenizer: tokenizer,
                configuration: resolvedConfiguration,
                directory: modelDirectory,
                options: options)
        }
        do {
            return try adopt(model)
        } catch RunnerError.unexpectedModel(let type) {
            for candidate in textTowerCandidates {
                do {
                    return try adopt(try candidate())
                } catch RunnerError.unexpectedModel {
                    continue
                }
            }
            throw RunnerError.unexpectedModel(type)
        }
    }

    /// The `model_type` a checkpoint declares. Public so the benchmark
    /// harnesses can key the same policy the serving path keys — they link
    /// `ProviderCore`, not `MLXRunners`.
    public static func checkpointModelType(at modelDirectory: URL) -> String? {
        try? RunnerCheckpoint.modelType(at: modelDirectory)
    }

    /// The runner type claiming a checkpoint, without adopting anything.
    /// Used by the assistant path, which needs the family's own drafter
    /// loader before any engine exists.
    static func runnerType(forCheckpointAt modelDirectory: URL) throws -> any Runner.Type {
        try RunnerRegistry.shared.resolve(
            modelType: RunnerCheckpoint.modelType(at: modelDirectory))
    }

    /// Decoder selection, from what the runner ACTUALLY holds.
    ///
    /// A decoder is present only when its drafter is resident, so `mtp` is
    /// selected when the caller wants speculation AND the runner reports it
    /// loaded. Asking for a decoder the runner does not have is a refusal,
    /// never a silent downgrade to serial — `mtp_active` must not claim a
    /// head that is not running. The refusal is the runner's own error type,
    /// not a provider copy of it.
    static func runnerDecoder(
        runner: any Runner,
        speculationRequested: Bool
    ) throws -> DecoderID {
        guard speculationRequested else { return .serial }
        guard runner.loadedDecoders.contains(.mtp) else {
            throw RunnerError.decoderNotLoaded(
                requested: DecoderID.mtp.rawValue,
                loaded: runner.loadedDecoders.map(\.rawValue))
        }
        return .mtp
    }

    /// Hand the slot's policy to the runner and take back the engine.
    ///
    /// The runner refuses a KV backend its manifest does not declare and a
    /// decoder it does not hold; both surface as `RunnerError` and are
    /// classified by `EngineV2RefusalReason.classify` onto the existing
    /// refusal path (ERROR `engine_v2_refusal` + throw → 503 → reroute).
    static func makeRunnerBuild(
        runner: any Runner,
        decoder: DecoderID,
        policy: EngineV2RunnerPolicy,
        pagedPoolDType: String? = nil
    ) throws -> ProductionBuild {
        let build = EngineBuild(
            kvBackend: policy.kvBackendKind == .paged ? .paged : .contiguous,
            kvBytesCapacity: policy.kvBytesCapacity,
            schedulerConfig: policy.schedulerConfig,
            loopConfig: policy.loopConfig,
            prefixCache: policy.prefixCache,
            decoder: decoder,
            mtpConfig: policy.mtpConfig,
            environment: policy.environment)
        let engine = try runner.makeEngine(build)
        return ProductionBuild(
            engine: engine,
            // The concrete engine reports its own post-resolution fixed
            // residency; a scripted engine in a test has none, and 0 is what
            // the scripted-engine path already reports.
            fixedRequestBytes: (engine as? EngineV2)?.resolvedFixedBytesPerRequest ?? 0,
            kvBackendKind: policy.kvBackendKind,
            kvBackendFallbackReason: policy.kvBackendFallbackReason,
            pagedPoolDType: policy.kvBackendKind == .paged ? pagedPoolDType : nil)
    }
}
