import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCore

/// Gate G2's live half: run ONE real model on BOTH KV backends and measure
/// everything `BackendParityCriteria` needs to render a verdict.
///
/// It drives the production seam, not a replica — `benchmarkServingModel` +
/// `EngineV2Factory.makeProductionBuild`, the same construction every serving
/// slot performs — and it compares RAW SAMPLED TOKEN IDS, never detokenized
/// text. Two different id streams can render to the same string, so a text
/// comparison is a weaker oracle than the one this gate is supposed to be.
///
/// Arms run STRICTLY SEQUENTIALLY over one loaded `ModelContainer`. Two live
/// engines on the same container race shared MLX/Metal state; and a 26B target
/// plus a paged pool plus a drafter is not something to hold twice.
///
/// Note on scope, so a PASS is not over-read: this harness calls the factory
/// directly and therefore BYPASSES the slot-routing policy
/// (`EngineV2KVBackendPolicy.applySlotVetoes`, applied by
/// `EngineV2SlotFactory`, not by `makeProductionBuild`). Every verdict here is
/// a statement about the BACKEND, never about how production routes a slot to
/// it. Whether a VLM slot reaches paged in production is a separate question
/// answered by the slot-factory suite, and it has moved during this wave — so
/// this harness deliberately does not encode an answer to it.
public enum BackendParityHarness {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Generated tokens per parity row. Long enough that a decode-kernel
        /// divergence has room to show; short enough to run in minutes.
        public var maxTokens: Int
        /// Rows submitted concurrently, at EQUAL prompt length, for the
        /// packed-prefill behavioural probe.
        public var packedProbeRows: Int
        /// Prompt length (tokens) for the packed probe rows.
        public var packedProbePromptTokens: Int
        /// Prompt length for the prefix-reuse probe. Two constraints, and the
        /// second is the binding one: matching is WHOLE-BLOCK (256 tokens),
        /// and a match shorter than the backend's frozen-replay bound is
        /// entirely replayed and saves nothing. For gemma-4 that bound is
        /// 25 windowed layers x 1024 = 25600 contiguous, +1 maxWindow = 26624
        /// paged, so the default clears the larger one by 8 blocks. Below it
        /// the criterion measures the prompt length, not the backend, and
        /// reports UNAVAILABLE saying so.
        public var prefixProbePromptTokens: Int
        /// Placeholder run length for the vision-span probe.
        public var visionSpanTokens: Int
        /// KV admission ceiling. Nil derives the same unified-memory budget a
        /// single-model provider slot would be granted.
        public var kvBytesCapacity: Int?

        public init(
            maxTokens: Int = 48,
            packedProbeRows: Int = 3,
            packedProbePromptTokens: Int = 192,
            prefixProbePromptTokens: Int = 28672,
            visionSpanTokens: Int = 8,
            kvBytesCapacity: Int? = nil
        ) {
            self.maxTokens = maxTokens
            self.packedProbeRows = packedProbeRows
            self.packedProbePromptTokens = packedProbePromptTokens
            self.prefixProbePromptTokens = prefixProbePromptTokens
            self.visionSpanTokens = visionSpanTokens
            self.kvBytesCapacity = kvBytesCapacity
        }
    }

    /// Natural-language parity prompts of deliberately different lengths, so
    /// rows join and leave the batch at different steps.
    static let parityPrompts: [String] = [
        "List three prime numbers.",
        "Explain, in two sentences, why the sky appears blue on a clear day.",
        "Summarize the tradeoffs between contiguous and paged key-value cache "
            + "layouts for transformer inference on unified-memory hardware, "
            + "covering memory waste, admission, and kernel dispatch overhead.",
    ]

    // MARK: - Entry point

    /// Run the gate. Never throws for a per-criterion failure — a failure is a
    /// verdict, not an error. It throws only when the MODEL itself cannot be
    /// loaded, i.e. when there is no run to report on at all.
    public static func run(
        modelID: String,
        modelDirectory: URL,
        assistantModelID: String? = nil,
        assistantDirectory: URL? = nil,
        configuration: Configuration = Configuration()
    ) async throws -> BackendParityReport {
        log("loading target \(modelID)")
        log("  path: \(modelDirectory.path)")

        let isVLM = ThroughputSweep.readHasVisionConfig(modelDirectory: modelDirectory)
        let container: ModelContainer
        if isVLM {
            container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: LocalTokenizerLoader())
        } else {
            container = try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory, using: LocalTokenizerLoader())
        }

        // The SERVING model is resolved EXACTLY ONCE and reused by every
        // engine build and by the drafter.
        //
        // This is not an optimization. For a VLM checkpoint
        // `benchmarkServingModel` runs `EngineV2VLMTextExtraction`, which
        // returns a NEW model object on each call. Calling it per engine bound
        // the drafter to one instance and every engine to another, and
        // `CBv2MTPRoundDriver.build` could then not prove target identity — it
        // returned nil and the run reported MTP inert on BOTH backends for a
        // reason that was entirely the harness's. Resolving once also keeps
        // the two arms on literally the same weights, so a token difference
        // can only be the backend.
        struct Facts: @unchecked Sendable {
            let weightBytes: Int
            let eosTokenIds: Set<Int>
            let prompts: [(name: String, tokens: [Int])]
            let seedTokens: [Int]
            let serving: ServingModel
        }
        let facts = try await container.perform { ctx -> Facts in
            let weightBytes = ctx.model.parameters().flattened().reduce(0) { $0 + $1.1.nbytes }
            let prompts = parityPrompts.map { text in
                (name: shortName(text), tokens: ctx.tokenizer.encode(text: text))
            }
            let seed = ctx.tokenizer.encode(
                text: ThroughputSweep.seedText, addSpecialTokens: false)
            let servingModel = try EngineV2Factory.benchmarkServingModel(
                model: ctx.model, isVLM: isVLM, modelDirectory: modelDirectory)

            // Both halves of the packed-prefill gate are consulted by the
            // engine loop; only the model half is publicly readable, so read
            // it off the real serving model rather than assuming it.
            let packedClaim =
                (servingModel as? CBv2LanguageModelPrefillForwardable)?
                .cbv2SupportsPackedPrefill ?? false
            let embeddable = servingModel as? CBv2EmbeddingForwardable
            let visionClaim = embeddable?.supportsVisionSpanPrefill ?? false

            // Build the span embedding through the model itself so it carries
            // the model's own hidden size and dtype. A hand-rolled zeros array
            // would probe the shape checker, not the span path.
            var spanEmbedding: MLXArray?
            if visionClaim, let embeddable, configuration.visionSpanTokens > 0 {
                let ids = MLXArray(
                    Array(repeating: Int32(0), count: configuration.visionSpanTokens)
                ).reshaped([1, configuration.visionSpanTokens])
                let embedded = embeddable.scaledInputEmbeddings(ids)
                eval(embedded)
                spanEmbedding = embedded
            }
            return Facts(
                weightBytes: weightBytes,
                eosTokenIds: ctx.configuration.eosTokenIds,
                prompts: prompts,
                seedTokens: seed.isEmpty ? [0] : seed,
                serving: ServingModel(
                    model: servingModel,
                    tokenizer: ctx.tokenizer,
                    claimsPackedPrefill: packedClaim,
                    claimsVisionSpans: visionClaim,
                    typeName: "\(type(of: servingModel))",
                    spanEmbedding: spanEmbedding))
        }
        log("  weights: \(String(format: "%.2f", Double(facts.weightBytes) / 1e9)) GB")
        log("  serving model: \(facts.serving.typeName) "
            + "(packedPrefill=\(facts.serving.claimsPackedPrefill), "
            + "visionSpans=\(facts.serving.claimsVisionSpans))")

        let kvCapacity = configuration.kvBytesCapacity ?? Int(min(
            UnifiedMemoryCap.kvBudgetBytes(
                physicalBytes: ProcessInfo.processInfo.physicalMemory,
                residentWeightBytes: UInt64(max(0, facts.weightBytes)),
                configReserveBytes: 0),
            UInt64(Int.max)))

        // The drafter is loaded ONCE and shared by both arms: a per-arm load
        // would make the MTP comparison a comparison of two drafters.
        var drafter: DrafterBox?
        var drafterFailure: String?
        if let assistantDirectory {
            do {
                drafter = try await loadDrafter(
                    serving: facts.serving, assistantDirectory: assistantDirectory)
                log("  drafter loaded: \(assistantModelID ?? assistantDirectory.lastPathComponent)")
            } catch {
                drafterFailure = "\(error)"
                log("  drafter unavailable: \(error)")
            }
        } else {
            drafterFailure = "no MTP assistant supplied (--assistant-model)"
        }

        var observations: [BackendParityObservation] = []
        for selection in [EngineV2KVBackendSelection.contiguous, .paged] {
            let observation = await measureArm(
                container: container,
                serving: facts.serving,
                selection: selection,
                kvCapacity: kvCapacity,
                facts: (
                    eos: facts.eosTokenIds, prompts: facts.prompts, seed: facts.seedTokens),
                drafter: drafter,
                drafterFailure: drafterFailure,
                configuration: configuration)
            observations.append(observation)
            Memory.clearCache()
        }

        let baseline = observations[0]
        let candidate = observations[1]
        return BackendParityReport(
            modelID: modelID,
            modelPath: modelDirectory.path,
            assistantModelID: assistantModelID,
            arms: observations.map(\.arm),
            criteria: BackendParityCriteria.evaluate(
                baseline: baseline, candidate: candidate),
            notes: makeNotes(baseline: baseline, candidate: candidate, isVLM: isVLM))
    }

    // MARK: - One backend

    /// The one serving model every engine and the drafter share, plus the
    /// model-level capability claims read off it. `@unchecked Sendable` by the
    /// same ownership-transfer argument as `MTPProductionModelBundle`: it is
    /// built once inside `container.perform` and only ever used from the
    /// serialized engine construction that follows.
    private struct ServingModel: @unchecked Sendable {
        let model: any LanguageModel
        let tokenizer: any MLXLMCommon.Tokenizer
        /// `CBv2LanguageModelPrefillForwardable.cbv2SupportsPackedPrefill`.
        let claimsPackedPrefill: Bool
        /// `CBv2EmbeddingForwardable.supportsVisionSpanPrefill`.
        let claimsVisionSpans: Bool
        let typeName: String
        /// Pre-built `[1, L, hidden]` span embedding for the vision probe, or
        /// nil when the model cannot produce one.
        let spanEmbedding: MLXArray?
    }

    private struct EngineBox: @unchecked Sendable {
        let engine: any CBv2Engine
        let kind: EngineV2KVBackendKind
        let fallbackReason: String?
    }

    /// `CBv2MTPDrafter` is `AnyObject` and deliberately NOT `Sendable` — it
    /// owns MLX module state. Ownership here is single-threaded by
    /// construction: the drafter is loaded once, and arms run strictly
    /// sequentially with each MTP engine shut down before the next is built,
    /// so it is only ever attached to one live engine at a time. Same
    /// ownership-transfer argument `MTPProductionModelBundle` makes.
    private struct DrafterBox: @unchecked Sendable {
        let drafter: any CBv2MTPDrafter
    }

    private static func measureArm(
        container: ModelContainer,
        serving: ServingModel,
        selection: EngineV2KVBackendSelection,
        kvCapacity: Int,
        facts: (eos: Set<Int>, prompts: [(name: String, tokens: [Int])], seed: [Int]),
        drafter: DrafterBox?,
        drafterFailure: String?,
        configuration: Configuration
    ) async -> BackendParityObservation {
        log("arm \(selection.rawValue): building engine")

        let box: EngineBox
        do {
            box = try await buildEngine(
                container: container, serving: serving,
                selection: selection, kvCapacity: kvCapacity,
                maxConcurrentRequests: max(configuration.packedProbeRows, 2),
                prefixCache: nil, drafter: nil, mtpConfig: CBv2MTPConfig())
        } catch {
            // Since OPEN-9 an explicit `.paged` REFUSES rather than degrading,
            // so this is the normal shape of "paged cannot serve this model".
            log("arm \(selection.rawValue): construction failed: \(error)")
            return BackendParityObservation(
                selection: selection.rawValue, constructionFailure: "\(error)")
        }
        log("arm \(selection.rawValue): resolved \(box.kind.rawValue)"
            + (box.fallbackReason.map { " (fallback: \($0))" } ?? ""))

        // 1. Token exactness — every prompt SOLO, in order. Solo removes batch
        //    composition as a variable so a cross-backend difference can only
        //    be the backend.
        var rows: [BackendParityObservation.Row] = []
        for prompt in facts.prompts {
            let row = await generate(
                engine: box.engine, id: UInt64(rows.count + 1), name: prompt.name,
                tokens: prompt.tokens, maxTokens: configuration.maxTokens, eos: facts.eos)
            rows.append(row)
            log("  row '\(prompt.name)': \(row.tokens.count) tokens, \(row.finishReason)")
        }

        // 2. Packed prefill and 3. vision spans, on the same engine.
        let packed = await probePackedPrefill(
            box: box, serving: serving, seed: facts.seed, eos: facts.eos,
            configuration: configuration)
        let vision = await probeVisionSpans(
            box: box, serving: serving, seed: facts.seed, eos: facts.eos,
            configuration: configuration)

        await box.engine.shutdown()
        Memory.clearCache()

        // 4. Prefix reuse needs its own engine: the factory only enables the
        //    scheduler's prefix cache when one is passed in.
        let prefixReuse = await probePrefixReuse(
            container: container, serving: serving,
            selection: selection, kvCapacity: kvCapacity, seed: facts.seed,
            eos: facts.eos, configuration: configuration)
        Memory.clearCache()

        // 5. MTP needs a third: a drafter cannot be attached after construction.
        let mtp = await probeMTP(
            container: container, serving: serving,
            selection: selection, kvCapacity: kvCapacity, prompts: facts.prompts,
            eos: facts.eos, drafter: drafter, drafterFailure: drafterFailure,
            configuration: configuration)
        Memory.clearCache()

        return BackendParityObservation(
            selection: selection.rawValue,
            resolvedBackend: box.kind.rawValue,
            fallbackReason: box.fallbackReason,
            rows: rows,
            mtp: mtp,
            packedPrefill: packed,
            visionSpans: vision,
            prefixReuse: prefixReuse)
    }

    // MARK: - Engine construction

    private static func buildEngine(
        container: ModelContainer,
        serving: ServingModel,
        selection: EngineV2KVBackendSelection,
        kvCapacity: Int,
        maxConcurrentRequests: Int,
        prefixCache: (any CBv2PrefixCache)?,
        drafter: DrafterBox?,
        mtpConfig: CBv2MTPConfig
    ) async throws -> EngineBox {
        // Inside `perform` for the same reason ThroughputSweep is: pool
        // allocation and the paged kernel preflight want serialized GPU
        // access. The serving model itself is NOT re-resolved here — see the
        // comment in `run`.
        try await container.perform { _ -> EngineBox in
            let build = try EngineV2Factory.makeProductionBuild(
                model: serving.model,
                tokenizer: serving.tokenizer,
                kvBytesCapacity: kvCapacity,
                prefixCache: prefixCache,
                maxConcurrentRequests: maxConcurrentRequests,
                mtpDrafter: drafter?.drafter,
                mtpConfig: mtpConfig,
                kvBackend: selection)
            return EngineBox(
                engine: build.engine,
                kind: build.kvBackendKind,
                fallbackReason: build.kvBackendFallbackReason)
        }
    }

    /// Bind the drafter to the SAME serving-model instance every engine will
    /// be built with. `CBv2MTPRoundDriver.build` proves target identity by
    /// object, so a second `benchmarkServingModel` call here would silently
    /// disable MTP on both backends.
    private static func loadDrafter(
        serving: ServingModel,
        assistantDirectory: URL
    ) async throws -> DrafterBox {
        guard let target = serving.model as? any Gemma4MTPTarget else {
            throw MTPBenchmarkError.mtpRequestedButInactive(
                "target model \(serving.typeName) is not Gemma4MTPTarget")
        }
        let assistant = try await Gemma4AssistantDraftModel.load(from: assistantDirectory)
        return DrafterBox(
            drafter: try Gemma4CBv2MTPDrafter(drafter: assistant, target: target))
    }

    // MARK: - Generation

    /// One greedy generation, collecting RAW token ids.
    private static func generate(
        engine: any CBv2Engine,
        id: UInt64,
        name: String,
        tokens: [Int],
        maxTokens: Int,
        eos: Set<Int>,
        prefixCacheEnabled: Bool = false,
        multimodal: CBv2MultimodalInput? = nil
    ) async -> BackendParityObservation.Row {
        let stream: AsyncStream<CBv2Event>
        do {
            stream = try engine.submit(CBv2Request(
                id: CBv2RequestID(id),
                promptTokens: tokens,
                sampling: CBv2SamplingParams(temperature: 0.0),
                maxTokens: maxTokens,
                stopTokens: eos,
                prefixCacheEnabled: prefixCacheEnabled,
                multimodal: multimodal))
        } catch {
            return BackendParityObservation.Row(
                prompt: name, tokens: [], finishReason: "submit_error: \(error)")
        }
        var collected: [Int] = []
        var reason = "unterminated"
        for await event in stream {
            switch event {
            case .delta(_, let emitted, _): collected.append(contentsOf: emitted)
            case .finished(let finish, _): reason = describe(finish)
            }
        }
        return BackendParityObservation.Row(
            prompt: name, tokens: collected, finishReason: reason)
    }

    /// Same, but also surfaces the terminal `CBv2Usage` (prefix-cache facts).
    private static func generateWithUsage(
        engine: any CBv2Engine,
        id: UInt64,
        name: String,
        tokens: [Int],
        maxTokens: Int,
        eos: Set<Int>
    ) async -> (row: BackendParityObservation.Row, usage: CBv2Usage?) {
        let stream: AsyncStream<CBv2Event>
        do {
            stream = try engine.submit(CBv2Request(
                id: CBv2RequestID(id),
                promptTokens: tokens,
                sampling: CBv2SamplingParams(temperature: 0.0),
                maxTokens: maxTokens,
                stopTokens: eos,
                prefixCacheEnabled: true))
        } catch {
            return (
                BackendParityObservation.Row(
                    prompt: name, tokens: [], finishReason: "submit_error: \(error)"),
                nil)
        }
        var collected: [Int] = []
        var reason = "unterminated"
        var usage: CBv2Usage?
        for await event in stream {
            switch event {
            case .delta(_, let emitted, _): collected.append(contentsOf: emitted)
            case .finished(let finish, let seen):
                reason = describe(finish)
                usage = seen
            }
        }
        return (
            BackendParityObservation.Row(
                prompt: name, tokens: collected, finishReason: reason),
            usage)
    }

    // MARK: - Probe: packed prefill

    /// Packed prefill has NO counter and NO engine-level accessor: the loop's
    /// decision (`EngineLoopV2`, `packedIDs`) is a step-local set that is
    /// discarded, and the bank that vouches for it is held behind `EngineV2`'s
    /// private loop. So this probe cannot report ACTIVE.
    ///
    /// What it CAN do is falsify. It submits `packedProbeRows` rows of EQUAL
    /// prompt length concurrently — precisely the shape the loop packs — and
    /// compares each row against the same prompt run solo. If packing ran and
    /// is wrong, the rows diverge and that is a definitive INACTIVE/FAIL. If
    /// they match, packing was either off (vacuous) or on and bit-identical
    /// (its contract), and the two are indistinguishable from out here — so
    /// the probe stays UNDETERMINED and names the accessor that would settle
    /// it, rather than banking a pass it did not earn.
    private static func probePackedPrefill(
        box: EngineBox,
        serving: ServingModel,
        seed: [Int],
        eos: Set<Int>,
        configuration: Configuration
    ) async -> BackendParityObservation.Capability {
        let rowCount = max(2, configuration.packedProbeRows)
        let length = max(8, configuration.packedProbePromptTokens)

        guard serving.claimsPackedPrefill else {
            return .undetermined(
                "model \(serving.typeName) does not claim "
                    + "CBv2LanguageModelPrefillForwardable.cbv2SupportsPackedPrefill, so the "
                    + "packed path is never taken for this model on EITHER backend — the "
                    + "backend's own claim cannot be reached through it")
        }

        // Distinct rotations, identical length: distinct so a cross-row leak
        // would change the output, identical length so the loop groups them.
        let prompts = (0 ..< rowCount).map { index in
            ThroughputSweep.tile(seed, to: length, offset: index * 7 + 1)
        }

        var solo: [BackendParityObservation.Row] = []
        for (index, tokens) in prompts.enumerated() {
            solo.append(await generate(
                engine: box.engine, id: UInt64(1000 + index), name: "packed-\(index)",
                tokens: tokens, maxTokens: configuration.maxTokens, eos: eos))
        }

        let engine = box.engine
        let maxTokens = configuration.maxTokens
        var concurrent = [BackendParityObservation.Row?](repeating: nil, count: rowCount)
        await withTaskGroup(of: (Int, BackendParityObservation.Row).self) { group in
            for (index, tokens) in prompts.enumerated() {
                group.addTask {
                    (index, await generate(
                        engine: engine, id: UInt64(2000 + index), name: "packed-\(index)",
                        tokens: tokens, maxTokens: maxTokens, eos: eos))
                }
            }
            for await (index, row) in group { concurrent[index] = row }
        }
        let batched = concurrent.compactMap { $0 }

        if let mismatch = BackendParityCriteria.rowMismatch(
            baseline: solo, candidate: batched)
        {
            return BackendParityObservation.Capability(
                active: false,
                detail: "\(rowCount) equal-length rows decoded concurrently diverged from the "
                    + "same rows run solo — the packed/batched prefill path is NOT "
                    + "bit-identical: \(mismatch)")
        }

        return .undetermined(
            "model claims packed prefill and \(rowCount) equal-length concurrent rows were "
                + "bit-identical to solo (necessary, not sufficient), but no public accessor "
                + "reports whether the packed path was TAKEN: "
                + "CBv2LayerCacheProvider.supportsPackedPrefill and EngineLoopV2's packedIDs "
                + "are both behind EngineV2's private loop. Needs an engine-side accessor or "
                + "packed-row counter on CBv2Engine to become PASS/FAIL")
    }

    // MARK: - Probe: vision spans

    /// Vision spans DO have a runtime gate: `CBv2Multimodal.validate` consults
    /// `cacheProvider.supportsMultimodalSpans` and throws
    /// `CBv2MultimodalError.unsupportedBackend` when the backend cannot honour
    /// span masks. So submit is a real capability read — and because the model
    /// gate is checked FIRST, a model-side refusal is distinguishable from a
    /// backend-side one and must not be reported as a backend regression.
    private static func probeVisionSpans(
        box: EngineBox,
        serving: ServingModel,
        seed: [Int],
        eos: Set<Int>,
        configuration: Configuration
    ) async -> BackendParityObservation.Capability {
        let spanLength = max(1, configuration.visionSpanTokens)
        guard serving.claimsVisionSpans else {
            return .undetermined(
                "model \(serving.typeName) reports supportsVisionSpanPrefill=false, so "
                    + "CBv2Multimodal.validate refuses at the MODEL gate before the backend's "
                    + "span capability is consulted — this says nothing about the backend")
        }
        guard let embedding = serving.spanEmbedding else {
            return .undetermined(
                "model claims vision-span prefill but no span embedding could be built from "
                    + "scaledInputEmbeddings")
        }

        // A text prefix, a placeholder run, a text suffix: the ordinary shape
        // of one image in a prompt.
        let prefix = ThroughputSweep.tile(seed, to: 24, offset: 3)
        let suffix = ThroughputSweep.tile(seed, to: 12, offset: 11)
        let placeholder = Array(repeating: seed[0], count: spanLength)
        let prompt = prefix + placeholder + suffix
        let span = CBv2ImageSpan(tokenOffset: prefix.count, length: spanLength)
        let input = CBv2MultimodalInput(spans: [span], embeddings: { [embedding] })

        let row = await generate(
            engine: box.engine, id: 3001, name: "vision-span", tokens: prompt,
            maxTokens: min(8, configuration.maxTokens), eos: eos, multimodal: input)

        if row.finishReason.hasPrefix("submit_error") {
            let message = row.finishReason
            let backendRefusal =
                message.contains("unsupportedBackend")
                || message.contains("cannot honor span attention masks")
            if backendRefusal {
                return BackendParityObservation.Capability(
                    active: false,
                    detail: "backend refused the span request: \(message)")
            }
            return .undetermined(
                "the span request was rejected for a non-backend reason: \(message)")
        }
        guard !row.tokens.isEmpty else {
            return .undetermined(
                "the span request was admitted but produced no tokens (\(row.finishReason))")
        }
        return BackendParityObservation.Capability(
            active: true,
            detail: "a \(spanLength)-token image span in a \(prompt.count)-token prompt was "
                + "admitted and served (\(row.tokens.count) tokens, \(row.finishReason))")
    }

    // MARK: - Probe: prefix reuse

    private static func probePrefixReuse(
        container: ModelContainer,
        serving: ServingModel,
        selection: EngineV2KVBackendSelection,
        kvCapacity: Int,
        seed: [Int],
        eos: Set<Int>,
        configuration: Configuration
    ) async -> BackendParityObservation.PrefixReuse {
        let cache = PrefixCacheV2(config: CBv2PrefixCacheConfig(
            promptContractID: "g2-parity", scopeID: "g2-parity"))
        let box: EngineBox
        do {
            box = try await buildEngine(
                container: container, serving: serving,
                selection: selection, kvCapacity: kvCapacity, maxConcurrentRequests: 2,
                prefixCache: cache, drafter: nil, mtpConfig: CBv2MTPConfig())
        } catch {
            return BackendParityObservation.PrefixReuse(
                unavailableReason: "prefix-cache engine construction failed: \(error)")
        }

        let capability = (box.engine as? EngineV2)?.prefixReuseCapability
        let supported = capability?.isSupported ?? false
        let strategy = capability?.strategy?.rawValue
        let unsupportedReason = capability?.unsupportedReason?.rawValue
        let replayBound = capability?.conservativeReplayBoundTokens ?? 0

        let promptTokens = max(512, configuration.prefixProbePromptTokens)
        let prompt = ThroughputSweep.tile(seed, to: promptTokens, offset: 5)

        // Cold request, then the SAME prompt again. Never overlapped: the
        // donation is published at the first request's terminal, off the
        // engine step thread, so an overlapping second request would race it
        // and report a miss for a reason that is not the backend's.
        let first = await generateWithUsage(
            engine: box.engine, id: 4001, name: "prefix-1", tokens: prompt,
            maxTokens: min(8, configuration.maxTokens), eos: eos)

        // ...and the terminal EVENT is not the donation either. Poll the cache
        // until the entry appears, exactly as CBv2MTPEngineMixedTests does
        // before its warm request. Without this the warm request races the
        // donation queue and the probe reports miss->miss on a backend that
        // reuses perfectly well.
        let donatedEntries = await waitForDonation(cache: cache)
        if donatedEntries == 0 {
            log("arm \(selection.rawValue): no prefix donation landed within "
                + "\(Self.donationTimeoutSeconds)s")
        }

        let second = await generateWithUsage(
            engine: box.engine, id: 4002, name: "prefix-2", tokens: prompt,
            maxTokens: min(8, configuration.maxTokens), eos: eos)
        let stats = cache.stats()

        // Shut down HERE, not in a defer-spawned Task: the next arm builds its
        // engine immediately and two live engines on one container race shared
        // MLX state.
        await box.engine.shutdown()

        guard let firstUsage = first.usage, let secondUsage = second.usage else {
            return BackendParityObservation.PrefixReuse(
                capabilitySupported: supported,
                capabilityStrategy: strategy,
                capabilityUnsupportedReason: unsupportedReason,
                replayBoundTokens: replayBound,
                promptTokens: promptTokens,
                donatedEntries: donatedEntries,
                unavailableReason: "no terminal usage was reported "
                    + "(\(first.row.finishReason) / \(second.row.finishReason))")
        }

        log("arm \(selection.rawValue): prefix reuse "
            + "\(describe(firstUsage.prefixCacheOutcome))->"
            + "\(describe(secondUsage.prefixCacheOutcome)), "
            + "matched=\(secondUsage.prefixCacheMatchedTokens), "
            + "saved=\(secondUsage.prefixCachePrefillTokensSaved), "
            + "replayBound=\(replayBound), prompt=\(promptTokens), donated=\(donatedEntries)")
        return BackendParityObservation.PrefixReuse(
            capabilitySupported: supported,
            capabilityStrategy: strategy,
            capabilityUnsupportedReason: unsupportedReason,
            replayBoundTokens: replayBound,
            promptTokens: promptTokens,
            donatedEntries: donatedEntries,
            firstOutcome: describe(firstUsage.prefixCacheOutcome),
            secondOutcome: describe(secondUsage.prefixCacheOutcome),
            secondMatchedTokens: max(
                secondUsage.prefixCacheMatchedTokens, secondUsage.prefixCacheHitTokens),
            secondPrefillTokensSaved: max(
                secondUsage.prefixCachePrefillTokensSaved, secondUsage.prefixCacheHitTokens),
            cacheHits: stats.hits,
            cacheMisses: stats.misses,
            cacheTokensSaved: stats.tokensSaved)
    }

    static let donationTimeoutSeconds = 10.0

    /// Poll until the cold request's donation is indexed, or the timeout
    /// elapses. Returns the entry count seen — 0 means it never landed, which
    /// the criterion reports as UNAVAILABLE rather than as a missed reuse.
    private static func waitForDonation(cache: PrefixCacheV2) async -> Int {
        let deadline = ContinuousClock.now.advanced(
            by: .milliseconds(Int(donationTimeoutSeconds * 1000)))
        while ContinuousClock.now < deadline {
            let entries = cache.stats().entryCount
            if entries > 0 { return entries }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return cache.stats().entryCount
    }

    // MARK: - Probe: MTP

    private static func probeMTP(
        container: ModelContainer,
        serving: ServingModel,
        selection: EngineV2KVBackendSelection,
        kvCapacity: Int,
        prompts: [(name: String, tokens: [Int])],
        eos: Set<Int>,
        drafter: DrafterBox?,
        drafterFailure: String?,
        configuration: Configuration
    ) async -> BackendParityObservation.MTP? {
        guard let drafter else {
            return BackendParityObservation.MTP(
                unavailableReason: drafterFailure ?? "no drafter")
        }
        // `.automatic` with a zero rectangular envelope performs NO speculative
        // work, which would look exactly like the silent no-op this criterion
        // hunts. Use the production policy's envelope, same as the MTP bench.
        let mtpConfig = CBv2MTPConfig(
            enabled: true,
            maxDraftTokens: CBv2MTPConfig.testedMaxDraftTokens,
            maxSpeculativeBatch: 8,
            verificationMode: .automatic,
            maxAutomaticRectangularTokens: MTPAutomaticVerificationPolicy.maxRectangularTokens())

        let box: EngineBox
        do {
            box = try await buildEngine(
                container: container, serving: serving,
                selection: selection, kvCapacity: kvCapacity, maxConcurrentRequests: 2,
                prefixCache: nil, drafter: drafter, mtpConfig: mtpConfig)
        } catch {
            return BackendParityObservation.MTP(
                unavailableReason: "MTP engine construction failed: \(error)")
        }

        var rows: [BackendParityObservation.Row] = []
        for (index, prompt) in prompts.enumerated() {
            rows.append(await generate(
                engine: box.engine, id: UInt64(5000 + index), name: prompt.name,
                tokens: prompt.tokens, maxTokens: configuration.maxTokens, eos: eos))
        }

        let engineV2 = box.engine as? EngineV2
        let metrics = engineV2?.mtpMetricsSnapshot()
        let observation = BackendParityObservation.MTP(
            rows: rows,
            driverConstructed: metrics != nil,
            inactiveReason: engineV2?.mtpInactiveReason,
            rounds: metrics?.rounds ?? 0,
            draftedTokens: metrics?.draftedTokens ?? 0,
            acceptedTokens: metrics?.acceptedTokens ?? 0,
            skippedRows: metrics?.skippedRows ?? [:],
            unavailableReason: engineV2 == nil
                ? "engine is \(type(of: box.engine)), not EngineV2 — MTP counters unreadable"
                : nil)
        log("arm \(selection.rawValue): MTP rounds=\(observation.rounds) "
            + "drafted=\(observation.draftedTokens) accepted=\(observation.acceptedTokens)")
        await box.engine.shutdown()
        return observation
    }

    // MARK: - Helpers

    private static func makeNotes(
        baseline: BackendParityObservation,
        candidate: BackendParityObservation,
        isVLM: Bool
    ) -> [String] {
        var notes: [String] = []
        notes.append(
            "verdicts describe the RESOLVED backends "
                + "(\(baseline.label) vs \(candidate.label)), not the requested selections "
                + "(\(baseline.selection) vs \(candidate.selection)).")
        notes.append(
            "this harness calls EngineV2Factory.makeProductionBuild directly and so bypasses "
                + "the slot-routing policy (EngineV2KVBackendPolicy.applySlotVetoes, applied by "
                + "EngineV2SlotFactory). Every verdict here is a BACKEND result, not a "
                + "statement about how production routes a slot to that backend."
                + (isVLM ? " This checkpoint IS a VLM and is served here through the "
                    + "text-extraction seam." : ""))
        notes.append(
            "token comparisons are over RAW SAMPLED TOKEN IDS with temperature 0; text "
                + "equality is a strictly weaker oracle and is not used.")
        return notes
    }

    static func shortName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return trimmed }
        return String(trimmed.prefix(37)) + "..."
    }

    static func describe(_ reason: CBv2FinishReason) -> String {
        switch reason {
        case .stop: return "stop"
        case .length: return "length"
        case .cancelled: return "cancelled"
        case .error(let message): return "error(\(message))"
        case .terminal(let cause, _): return "terminal(\(cause))"
        }
    }

    static func describe(_ outcome: CBv2PrefixCacheOutcome) -> String {
        switch outcome {
        case .disabled: return "disabled"
        case .skippedPolicy: return "skipped_policy"
        case .miss: return "miss"
        case .hit: return "hit"
        case .skippedCapacity: return "skipped_capacity"
        case .adoptionFailed: return "adoption_failed"
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[parity] \(message)\n".utf8))
    }
}
