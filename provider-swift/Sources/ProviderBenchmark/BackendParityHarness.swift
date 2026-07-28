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
                (name: shortName(text), tokens: chatPromptTokens(
                    tokenizer: ctx.tokenizer, text: text))
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

        // The control runs LAST: it needs the candidate arm's rows to compare
        // against, and running it after both arms keeps only one live engine
        // on the container at a time.
        let control = await probeNumericsControl(
            container: container,
            serving: facts.serving,
            candidate: candidate,
            kvCapacity: kvCapacity,
            facts: (eos: facts.eosTokenIds, prompts: facts.prompts),
            configuration: configuration)
        Memory.clearCache()

        return BackendParityReport(
            modelID: modelID,
            modelPath: modelDirectory.path,
            assistantModelID: assistantModelID,
            arms: observations.map(\.arm),
            numericsControl: control,
            criteria: BackendParityCriteria.evaluate(
                baseline: baseline, candidate: candidate, control: control),
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
        /// Dtype of the pages the PAGED pool was ACTUALLY built with, nil on
        /// contiguous. Read off the constructed pool by the factory, so the
        /// fp32 control arm can prove fp32 served rather than assuming the
        /// env knob was honoured.
        let pagedPoolDType: String?
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
                tokens: prompt.tokens, maxTokens: configuration.maxTokens, eos: facts.eos,
                topLogprobs: 2)
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
        mtpConfig: CBv2MTPConfig,
        environmentOverrides: [String: String] = [:]
    ) async throws -> EngineBox {
        // Inside `perform` for the same reason ThroughputSweep is: pool
        // allocation and the paged kernel preflight want serialized GPU
        // access. The serving model itself is NOT re-resolved here — see the
        // comment in `run`.
        let environment = environmentOverrides.isEmpty
            ? ProcessInfo.processInfo.environment
            : ProcessInfo.processInfo.environment.merging(environmentOverrides) { _, new in new }
        return try await container.perform { _ -> EngineBox in
            let build = try EngineV2Factory.makeProductionBuild(
                model: serving.model,
                tokenizer: serving.tokenizer,
                kvBytesCapacity: kvCapacity,
                maxConcurrentRequests: maxConcurrentRequests,
                prefixCache: prefixCache,
                mtpDrafter: drafter?.drafter,
                mtpConfig: mtpConfig,
                kvBackend: selection,
                environment: environment)
            return EngineBox(
                engine: build.engine,
                kind: build.kvBackendKind,
                fallbackReason: build.kvBackendFallbackReason,
                pagedPoolDType: build.pagedPoolDType)
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

    /// One greedy generation, collecting RAW token ids and — when
    /// `topLogprobs >= 2` — the per-token argmax slack.
    ///
    /// The slack is what lets the report say whether a cross-backend token
    /// difference was even resolvable at the precision the KV is stored in.
    /// Requesting it costs a top-k on rows that ask; rows that do not ask pay
    /// nothing (`DefaultSamplerV2` takes the batch max).
    private static func generate(
        engine: any CBv2Engine,
        id: UInt64,
        name: String,
        tokens: [Int],
        maxTokens: Int,
        eos: Set<Int>,
        prefixCacheEnabled: Bool = false,
        multimodal: CBv2MultimodalInput? = nil,
        topLogprobs: Int = 0
    ) async -> BackendParityObservation.Row {
        let stream: AsyncStream<CBv2Event>
        do {
            stream = try engine.submit(CBv2Request(
                id: CBv2RequestID(id),
                promptTokens: tokens,
                sampling: CBv2SamplingParams(temperature: 0.0, topLogprobs: topLogprobs),
                maxTokens: maxTokens,
                stopTokens: eos,
                prefixCacheEnabled: prefixCacheEnabled,
                multimodal: multimodal))
        } catch {
            return BackendParityObservation.Row(
                prompt: name, tokens: [], finishReason: "submit_error: \(error)")
        }
        var collected: [Int] = []
        var margins: [Float] = []
        var reason = "unterminated"
        for await event in stream {
            switch event {
            case .delta(_, let emitted, let logprobs):
                collected.append(contentsOf: emitted)
                guard let logprobs else { continue }
                for entry in logprobs {
                    // Softmax is monotone, so the top1-top2 LOGPROB gap is the
                    // top1-top2 LOGIT gap. A single candidate means the
                    // runner-up was not requested; record no slack rather than
                    // inventing infinite confidence.
                    let ranked = entry.topLogprobs.map(\.logprob).sorted(by: >)
                    guard ranked.count >= 2 else { continue }
                    margins.append(ranked[0] - ranked[1])
                }
            case .finished(let finish, _): reason = describe(finish)
            }
        }
        return BackendParityObservation.Row(
            prompt: name, tokens: collected, finishReason: reason, margins: margins)
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

    /// Packed prefill, measured rather than assumed.
    ///
    /// `CBv2Engine.packedPrefillActivity()` separates the two questions that
    /// matter: `isSupported` is CONFIGURATION (both capability gates agree,
    /// so the engine MAY pack) and `groupsExecuted` is EVIDENCE (a rectangular
    /// `[B > 1, chunk]` forward actually happened). A claimed-but-never-packed
    /// backend reports supported with zero counters — the exact analogue of
    /// the MTP silent no-op — so this probe gates on the counters, never on
    /// the flag, as the accessor's own contract requires.
    ///
    /// The counters are cumulative and monotonic per engine instance, so the
    /// probe DIFFERENCES them across the concurrent batch. An absolute read
    /// would prove the engine packed at some point in its life, not that it
    /// packed for the rows just submitted — and the solo baseline runs first,
    /// which would poison exactly that reading.
    ///
    /// Three ways this could read zero for reasons that are not a backend
    /// fault, all avoided by construction: MTP rounds never pack (this engine
    /// is built with no drafter), an adopted prefix leaves nothing to chunk
    /// (built with no prefix cache, and the requests set
    /// `prefixCacheEnabled: false`), and a token budget below
    /// `rows * chunk` splits the last row into its own group (so the verdict
    /// keys on `groupsExecuted > 0`, never on `rowsExecuted == rowCount`).
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
                    + "packed path is never taken for this model on EITHER backend — that "
                    + "is a MODEL fact and says nothing about the backend")
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
        let before = engine.packedPrefillActivity()
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
        let after = engine.packedPrefillActivity()
        let groups = after.groupsExecuted - before.groupsExecuted
        let rows = after.rowsExecuted - before.rowsExecuted
        let batched = concurrent.compactMap { $0 }

        // Bit-identity outranks everything: if the rows diverge, packing ran
        // and is WRONG, which is a harder failure than not packing at all.
        if let mismatch = BackendParityCriteria.rowMismatch(
            baseline: solo, candidate: batched)
        {
            return BackendParityObservation.Capability(
                active: false,
                detail: "\(rowCount) equal-length rows decoded concurrently diverged from the "
                    + "same rows run solo — the packed/batched prefill path is NOT "
                    + "bit-identical (\(groups) packed group(s) over \(rows) row(s) ran "
                    + "during the batch): \(mismatch)")
        }

        guard after.isSupported else {
            return BackendParityObservation.Capability(
                active: false,
                detail: "the model claims packed prefill but the engine reports "
                    + "isSupported=false, so the CACHE half refused — a layer cache in this "
                    + "backend's bank does not vouch for keepsRowsIndependentWhenPacked")
        }

        guard groups > 0 else {
            return BackendParityObservation.Capability(
                active: false,
                detail: "packed prefill is supported but NEVER EXECUTED: \(rowCount) "
                    + "equal-length rows submitted concurrently produced 0 rectangular "
                    + "forwards. Claimed-but-never-packed, the same shape as a silent no-op")
        }

        return BackendParityObservation.Capability(
            active: true,
            detail: "\(groups) rectangular packed forward(s) carrying \(rows) prompt row(s) "
                + "executed for \(rowCount) equal-length concurrent rows, and every row was "
                + "bit-identical to the same prompt run solo")
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
        //
        // The completion budget is the adoption oracle's WINDOW, not decor.
        // It was hardcoded `min(8, ...)` when this probe only had to observe
        // that reuse happened; now that the two streams are compared for
        // exactness, an 8-token window cannot see a divergence at token 20 —
        // which is exactly where the measured paged adoption defect appears.
        // A truncated window reports "exact" for a defect it stopped before,
        // so the operator's `--parity-max-tokens` governs it.
        let adoptionWindow = max(1, configuration.maxTokens)
        let first = await generateWithUsage(
            engine: box.engine, id: 4001, name: "prefix-1", tokens: prompt,
            maxTokens: adoptionWindow, eos: eos)

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
            maxTokens: adoptionWindow, eos: eos)
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

        // Whether ADOPTION CHANGED THE ANSWER. Both submissions carry the
        // SAME prompt at temperature 0, so under exact adoption the two token
        // streams are identical and any difference is the reuse path
        // rewriting the output — which the savings comparison, counting
        // tokens it did not have to prefill, cannot see at all. Main measured
        // paged adopted diverging from paged cold at token 20 of 32 on
        // gemma-4 at a 28,672-token prompt while this criterion returned
        // PASS; this is the data that catches it, and it was already sitting
        // in the probe being discarded.
        //
        // Gated on an actual `.hit`: on a miss there is no adoption to judge
        // and a difference would be nondeterminism, a different finding with
        // a different owner. nil is NOT MEASURED, never "exact".
        //
        // Exactness compares the whole TERMINAL OUTCOME, not just the token
        // IDs — `judgeAdoptionExactness` holds the rule and the reasons.
        let adopted = secondUsage.prefixCacheOutcome == .hit
        let exactness: (exact: Bool, mismatchReason: String?)? = adopted
            ? Self.judgeAdoptionExactness(
                coldTokens: first.row.tokens,
                adoptedTokens: second.row.tokens,
                coldFinish: first.row.finishReason,
                adoptedFinish: second.row.finishReason)
            : nil
        let adoptionTokenExact: Bool? = exactness?.exact
        let adoptionMismatchReason: String? = exactness?.mismatchReason
        // The window the comparison ACTUALLY covered. A verdict of "exact"
        // over 8 tokens and one over 48 are different claims and must not
        // print the same; the shorter stream bounds what could be observed.
        let adoptionComparedTokens = adopted
            ? min(first.row.tokens.count, second.row.tokens.count)
            : 0
        // The backend this PROBE actually built, not the one requested. The
        // probe constructs its own engine per arm, so it can degrade
        // independently of the arm engine (kill switch, kernel preflight, a
        // binary copied without its resource bundle). A silently-contiguous
        // arm reporting "paged adoption exact" is the precise failure this
        // criterion exists to prevent.
        log("arm \(selection.rawValue): prefix reuse "
            + "\(describe(firstUsage.prefixCacheOutcome))->"
            + "\(describe(secondUsage.prefixCacheOutcome)), "
            + "resolved=\(box.kind.rawValue), "
            + "finish=\(first.row.finishReason)/\(second.row.finishReason), "
            + "adoptionExact=\(adoptionTokenExact.map(String.init) ?? "not_measured") "
            + "over \(adoptionComparedTokens) tokens, "
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
            firstFinishReason: first.row.finishReason,
            secondFinishReason: second.row.finishReason,
            secondMatchedTokens: max(
                secondUsage.prefixCacheMatchedTokens, secondUsage.prefixCacheHitTokens),
            secondPrefillTokensSaved: max(
                secondUsage.prefixCachePrefillTokensSaved, secondUsage.prefixCacheHitTokens),
            cacheHits: stats.hits,
            cacheMisses: stats.misses,
            cacheTokensSaved: stats.tokensSaved,
            adoptionTokenExact: adoptionTokenExact,
            adoptionMismatchReason: adoptionMismatchReason,
            adoptionComparedTokens: adoptionComparedTokens,
            probeResolvedBackend: box.kind.rawValue,
            probeFallbackReason: box.fallbackReason)
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

    // MARK: - Probe: same-backend numerics control

    /// Rebuild the CANDIDATE backend with fp32 pages and re-run the parity
    /// prompts against it.
    ///
    /// This is the control a cross-backend token comparison cannot perform on
    /// itself: if flipping the pool dtype — a change that alters no
    /// algorithm, only storage precision — moves the tokens, then a benign
    /// perturbation is enough to move them and the cross-backend difference
    /// is not attributable to the backend. Establishing that PER RUN and PER
    /// MODEL is the point; inheriting it from a one-off experiment in
    /// someone's notes is not the same thing.
    ///
    /// Reachable only since `DARKBLOOM_CBV2_PAGED_KV_DTYPE` landed. The other
    /// candidate lever, `CBv2AttentionV1.queryBlockSize`, is a process-wide
    /// `static let` resolved from `ProcessInfo` at first touch and cannot be
    /// varied in-process at all.
    private static func probeNumericsControl(
        container: ModelContainer,
        serving: ServingModel,
        candidate: BackendParityObservation,
        kvCapacity: Int,
        facts: (eos: Set<Int>, prompts: [(name: String, tokens: [Int])]),
        configuration: Configuration
    ) async -> BackendParityReport.NumericsControl {
        let perturbation = "paged pool dtype float16 -> float32"

        guard candidate.resolvedBackend == EngineV2KVBackendKind.paged.rawValue,
            !candidate.rows.isEmpty
        else {
            return .init(
                perturbation: perturbation, tokenExact: nil,
                detail: "the candidate arm did not serve paged rows "
                    + "(resolved \(candidate.resolvedBackend ?? "nothing"), "
                    + "\(candidate.rows.count) rows), so there is nothing to perturb")
        }

        let box: EngineBox
        do {
            box = try await buildEngine(
                container: container, serving: serving, selection: .paged,
                kvCapacity: kvCapacity,
                maxConcurrentRequests: max(configuration.packedProbeRows, 2),
                prefixCache: nil, drafter: nil, mtpConfig: CBv2MTPConfig(),
                // Literal rather than EngineV2Factory.pagedPoolDTypeEnvKey:
                // that constant is internal to ProviderCore.
                environmentOverrides: ["DARKBLOOM_CBV2_PAGED_KV_DTYPE": "float32"])
        } catch {
            return .init(
                perturbation: perturbation, tokenExact: nil,
                detail: "the fp32 control engine would not build: \(error)")
        }

        // Trust the arm ONLY on the RESOLVED dtype. A silently ignored knob
        // would hand back a second fp16 arm that agrees with the first and
        // looks like a clean control — the precise failure this gate exists
        // to catch, and the one it would be most embarrassing to ship inside.
        guard box.pagedPoolDType == "float32" else {
            await box.engine.shutdown()
            return .init(
                perturbation: perturbation, tokenExact: nil,
                detail: "requested fp32 pages but the pool resolved "
                    + "\(box.pagedPoolDType ?? "nil") — the perturbation never happened, "
                    + "so this arm is NOT a control")
        }

        var rows: [BackendParityObservation.Row] = []
        for (index, prompt) in facts.prompts.enumerated() {
            rows.append(await generate(
                engine: box.engine, id: UInt64(6000 + index), name: prompt.name,
                tokens: prompt.tokens, maxTokens: configuration.maxTokens, eos: facts.eos,
                topLogprobs: 2))
        }

        // Shut the fp32 engine down BEFORE any verdict below: each one is
        // terminal for this arm, and an early return that skipped the
        // shutdown would leave a second multi-GiB pool resident for the rest
        // of the run.
        await box.engine.shutdown()
        Memory.clearCache()

        // fp32 pages halve the seats AND, per P4_FrozenChunkGather, run under
        // an admission ledger that still charges 2 bytes/element
        // (`CBv2PrefixReuseCapability.fullKVBytesPerToken` hardcodes it and
        // `derive` never sees a dtype), so the fp32 arm's admitted
        // concurrency is NOT comparable to the fp16 arm's. That is harmless
        // for this control only because admission never binds at probe size —
        // three short prompts, run SEQUENTIALLY, against a multi-GiB pool.
        // Verify rather than assume it: a capacity refusal would surface as a
        // submit error or a non-clean terminal, and would make the arm
        // measure admission instead of numerics.
        //
        // The clean-terminal ALLOWLIST is shared with the prefix-reuse
        // probe's adoption-exactness judge (`Self.cleanTerminals`) so the
        // two probes can never disagree about what "ended cleanly" means.
        let unclean = rows.filter { !Self.cleanTerminals.contains($0.finishReason) }
        guard unclean.isEmpty else {
            return .init(
                perturbation: perturbation, tokenExact: nil,
                detail: "the fp32 control arm hit \(unclean.count) non-clean terminal(s) "
                    + "(\(unclean.map(\.finishReason).joined(separator: "; "))) — fp32 halves "
                    + "the pool's seats and its byte accounting under-counts, so this arm "
                    + "measured admission rather than numerics and is NOT a control")
        }

        // Rows that EXIST but carry no tokens compare equal, and `rowMismatch`
        // is blind to that by construction, so the exactness branch below
        // would book "the perturbation changed nothing" off a control that
        // decoded nothing — absence rendered as agreement, the same defect the
        // token criterion refuses one layer up. Same helper as that criterion,
        // deliberately, so the two can never drift apart.
        if let blocker = BackendParityCriteria.zeroEvidenceBlocker(
            baselineLabel: "paged fp16 pages", baselineRows: candidate.rows,
            candidateLabel: "paged fp32 pages", candidateRows: rows)
        {
            return .init(
                perturbation: perturbation, tokenExact: nil,
                detail: "the control could not be scored — \(blocker)")
        }

        if let mismatch = BackendParityCriteria.rowMismatch(
            baseline: candidate.rows, candidate: rows)
        {
            log("control: paged fp32 vs paged fp16 NOT token-exact — \(mismatch)")
            return .init(
                perturbation: perturbation, tokenExact: false,
                detail: "paged with fp32 pages diverged from paged with fp16 pages on the "
                    + "SAME backend: \(mismatch)",
                firstFlip: mismatch)
        }

        // Carry the SAMPLE SIZE into the verdict. "Token-exact" over three
        // one-token rows — what an instruct checkpoint gives you when the
        // parity prompts reach it untemplated and it stops immediately — and
        // token-exact over 144 tokens are the same word for very different
        // evidence, and this string is what someone deciding whether a
        // divergence is precision-related actually reads.
        let total = rows.reduce(0) { $0 + $1.tokens.count }
        let shortest = rows.map(\.tokens.count).min() ?? 0
        log("control: paged fp32 vs paged fp16 token-exact over \(total) tokens "
            + "(shortest row \(shortest))")
        return .init(
            perturbation: perturbation, tokenExact: true,
            detail: "paged with fp32 pages produced token ids IDENTICAL to paged with fp16 "
                + "pages across \(rows.count) prompts and \(total) tokens (shortest row "
                + "\(shortest)), so this model's argmax survives a benign storage-precision "
                + "change over that many decode steps")
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

        // NO `topLogprobs` here, deliberately. MTP verification bypasses the
        // sampler and emits raw target argmaxes; asking a row for top-k
        // logprobs pulls it back onto the sampler path and the drafter stops
        // engaging — measured, not theorised: adding it took this arm from
        // rounds=5/drafted=5 to rounds=0/drafted=0 on both backends while
        // `driverConstructed` stayed true, i.e. it manufactured exactly the
        // silent no-op this criterion exists to detect. The margin instrument
        // belongs to the base decode comparison only.
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

    /// Tokenize a parity prompt the way PRODUCTION tokenizes one: through the
    /// checkpoint's chat template.
    ///
    /// Not cosmetic, and not a fidelity nicety. An instruct checkpoint handed
    /// a bare completion string answers it the way the base model would —
    /// which on `gemma-4-e2b-it-4bit` means emitting end-of-turn IMMEDIATELY.
    /// Measured: every parity row returned `1 tokens, stop`, so the numerics
    /// control compared THREE argmax decisions and reported TOKEN-EXACT, a
    /// confident-sounding verdict drawn from a sample with no power to
    /// contradict it. The gate could not fail there because the decode ended
    /// before it started. e2b is also the checkpoint the measured paged
    /// adoption divergence lives on, so it is precisely the one the control
    /// must be able to speak about.
    ///
    /// gpt-oss and gemma-4-26B already decoded their full budget untemplated,
    /// so this changes what those two are asked, not whether they answer.
    ///
    /// A tokenizer with no usable template falls back to raw encoding and the
    /// caller SAYS SO on stderr. Silently serving a different prompt shape
    /// than the one claimed is the failure this whole harness is built to
    /// refuse.
    static func chatPromptTokens(
        tokenizer: any Tokenizer,
        text: String
    ) -> [Int] {
        let messages: [[String: any Sendable]] = [["role": "user", "content": text]]
        if let templated = try? tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: nil),
            !templated.isEmpty
        {
            return templated
        }
        log("  prompt '\(shortName(text))': NO USABLE CHAT TEMPLATE — falling back to raw "
            + "text. An instruct checkpoint may answer a bare completion prompt with an "
            + "immediate end-of-turn, which yields a one-token row and a control with no "
            + "power; check the row lengths before trusting any verdict from this run.")
        return tokenizer.encode(text: text)
    }

    static func shortName(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return trimmed }
        return String(trimmed.prefix(37)) + "..."
    }

    /// Terminals a request may end with and still count as a valid
    /// comparand: the model stopped (`stop`) or the budget ran out
    /// (`length`). An ALLOWLIST, not a blocklist of known-bad prefixes:
    /// `describe(CBv2FinishReason)` can grow a case, and `generateWithUsage`
    /// adds two reasons of its own (`submit_error:`, `unterminated`) that no
    /// `CBv2FinishReason` spells — a blocklist waves through every reason
    /// nobody thought to enumerate, which is the shape of gate this harness
    /// exists to refuse. Shared by the fp32 numerics control and the
    /// prefix-reuse adoption-exactness judge.
    static let cleanTerminals: Set<String> = ["stop", "length"]

    /// Whether the ADOPTING request reproduced the cold request's outcome —
    /// the WHOLE outcome, not just the token IDs. The same tokens under
    /// different finish reasons (`stop` on the cold arm, `length` or
    /// `error(…)` on the adopted one) mean adoption changed how the request
    /// ENDED, and a non-clean terminal on either stream means at least one
    /// comparand was cut short by machinery (an engine error, a forced
    /// terminal, a submit failure) rather than by the model — its token
    /// stream is a truncation artifact, and "the truncated prefixes agree"
    /// is not the claim `adoptionTokenExact = true` makes.
    ///
    /// Returns `exact` plus a mismatch reason naming the SHAPE of the
    /// failure, because the shapes are different findings: diverging tokens
    /// can be precision drift on a sensitive checkpoint (see the symmetric
    /// arm of the criterion), while a terminal mismatch never is. Pure and
    /// static so the rule is unit-testable without an engine.
    static func judgeAdoptionExactness(
        coldTokens: [Int],
        adoptedTokens: [Int],
        coldFinish: String,
        adoptedFinish: String
    ) -> (exact: Bool, mismatchReason: String?) {
        var reasons: [String] = []
        if coldTokens != adoptedTokens {
            reasons.append("token streams diverged")
        }
        if coldFinish != adoptedFinish {
            reasons.append(
                "terminal mismatch: cold finished '\(coldFinish)', "
                    + "adopted finished '\(adoptedFinish)'")
        } else if !cleanTerminals.contains(coldFinish) {
            // Identical but unclean: both arms were cut short the same way,
            // so neither stream is the model's answer and the comparison
            // proves nothing about adoption.
            reasons.append("non-clean terminal on both arms: '\(coldFinish)'")
        }
        // The mismatched-terminal case can also hide an UNCLEAN side; name
        // it too, so `error(…)` is never summarized as a mere mismatch.
        if coldFinish != adoptedFinish {
            let unclean = [("cold", coldFinish), ("adopted", adoptedFinish)]
                .filter { !cleanTerminals.contains($0.1) }
            if !unclean.isEmpty {
                reasons.append(
                    "non-clean terminal on "
                        + unclean.map { "\($0.0) ('\($0.1)')" }
                            .joined(separator: " and "))
            }
        }
        guard reasons.isEmpty else {
            return (false, reasons.joined(separator: "; "))
        }
        return (true, nil)
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
