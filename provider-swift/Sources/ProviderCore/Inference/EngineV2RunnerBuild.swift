// Copyright © 2026 Eigen Labs.
//
// The runner boundary, provider side (Darkbloom runner contract §3, §5, §9,
// §12c).
//
// One runner is one model family behind the CBv2 engine, with a static
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
// Nothing here decides policy. `EngineV2SlotFactory` and
// `EngineV2Factory.prepareProductionBackend` still own the KV-backend
// selection, the slot vetoes, the kill switch, the crash-loop guard, the
// paged physical-capacity plan, the prefix-cache construction gate, and the
// degrade-or-refuse ladder; this file is where their verdict is handed to a
// runner. The result keeps the shape the rest of the provider already reads
// (`EngineV2Factory.ProductionBuild`), so the bridge, the shared KV ledger,
// the heartbeat clamp, and the `engine_v2_refusal` telemetry path are
// unchanged.
//
// STATE: this is the whole runner path and it is exercised by
// `EngineV2RunnerBuildTests` with a scripted runner. The SERVING slot does
// not take it yet — the provider's model lifecycle owns an already-resident
// `ModelContainer` and `Runner.load` loads the checkpoint itself, so routing
// the slot through here today would load the weights twice. The families
// that still load through `ModelContainerLoading` keep the typed adaptation
// in `EngineV2ModelAdaptation`. Qwen 3.8 Flash-Next has no such adaptation
// on purpose: its forward pass needs the n-gram row source, which only
// `Runner.load` can be given.

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
    /// telemetry, exactly as the container path reports it.
    var kvBackendFallbackReason: String?
    /// The slot's live-KV grant, already re-sliced against co-resident slots
    /// and clamped to physical memory.
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
    /// itself (the fork's loader drops the `ngram_embedding` shards before
    /// the model materializes them, so they stay on disk for this reader).
    /// A path to a single file is refused by the reader, by name.
    static func runnerResources(modelDirectory: URL) -> RunnerResources {
        var resources = RunnerResources()
        // `isDirectory: true` explicitly: the reader refuses a file by name,
        // and a URL built from a path alone does not carry the distinction
        // until the path exists on disk.
        resources[Qwen4ExpRunner.ngramRowSourceResource] =
            URL(fileURLWithPath: modelDirectory.path, isDirectory: true) as NSURL
        return resources
    }

    /// What the caller wants honored at load time. The runner never
    /// downloads and never reads the network.
    static func runnerLoadOptions(
        modelDirectory: URL,
        drafterDirectory: URL? = nil,
        kvBytesCapacity: Int,
        maxSequenceLength: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RunnerLoadOptions {
        RunnerLoadOptions(
            drafterDirectory: drafterDirectory,
            kvBytesCapacity: kvBytesCapacity,
            maxSequenceLength: maxSequenceLength,
            environment: environment,
            resources: runnerResources(modelDirectory: modelDirectory))
    }

    /// Resolve the family through the registry and load it. This is the one
    /// place a checkpoint becomes a runner: `model_type` from the
    /// checkpoint's own `config.json`, then the registry, then the runner's
    /// own loader. Darkbloom names no family on this path.
    static func loadRunner(
        modelDirectory: URL,
        options: RunnerLoadOptions
    ) async throws -> any Runner {
        let runnerType = try RunnerRegistry.shared.resolve(checkpoint: modelDirectory)
        return try await runnerType.load(modelDirectory, options: options)
    }

    /// Decoder selection, from what the runner ACTUALLY loaded.
    ///
    /// This is the runner-path form of the provider's MTP assistant
    /// resolution: a decoder is present only when its drafter is resident,
    /// so `mtp` is selected when the caller wants speculation AND the runner
    /// reports it loaded, and `serial` otherwise. Asking for a decoder the
    /// runner did not load is a refusal, never a silent downgrade to serial
    /// — the caller's `mtp_active` telemetry would otherwise claim a head
    /// that is not running.
    static func runnerDecoder(
        runner: any Runner,
        speculationRequested: Bool
    ) throws -> DecoderID {
        guard speculationRequested else { return .serial }
        guard runner.loadedDecoders.contains(.mtp) else {
            // The runner's own refusal, not a provider copy of it: the same
            // condition is checked again inside `makeEngine`, and one error
            // type keeps the two answers indistinguishable to whoever reads
            // the refusal.
            throw RunnerError.decoderNotLoaded(
                requested: DecoderID.mtp.rawValue,
                loaded: runner.loadedDecoders.map(\.rawValue))
        }
        return .mtp
    }

    /// Hand the slot's policy to the runner and take back the engine.
    ///
    /// The runner refuses a KV backend its manifest does not declare and a
    /// decoder it did not load; both surface as `RunnerError` and are
    /// classified by `EngineV2RefusalReason.classify` onto the existing
    /// refusal path (ERROR `engine_v2_refusal` + throw → 503 → reroute).
    static func makeRunnerBuild(
        runner: any Runner,
        decoder: DecoderID,
        policy: EngineV2RunnerPolicy
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
            // Page dtype is a PAGED pool's own property. No runner in the
            // fork declares paged today, and the runner's assembly builds
            // its pool from `EngineBuild` alone, so there is no constructed
            // pool to report here. Reporting nil keeps the rule the
            // container path states: only a pool that exists names its
            // dtype.
            pagedPoolDType: nil)
    }
}
