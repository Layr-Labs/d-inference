// Gate G2's live probes, driven through a scripted engine. The probes own
// the rules that turn engine events and packed-prefill counters into a
// capability verdict; those rules need no model, so they are checked here.
// Engine construction and the real model stay in the live suites.

import Foundation
import MLX
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

private final class ParityProbeStubModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct ParityProbeProcessorError: Error {}

private struct ParityProbeProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput {
        throw ParityProbeProcessorError()
    }
}

private struct ParityProbeTemplateError: Error {}

/// Encodes text as `[character count, 1 when special tokens are added]` and
/// renders the chat template from a fixed reply.
private struct ParityProbeTokenizer: MLXLMCommon.Tokenizer {
    let template: [Int]?

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        [text.count, addSpecialTokens ? 1 : 0]
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        guard let template else { throw ParityProbeTemplateError() }
        return template
    }
}

@Suite("gate G2: harness probes with a scripted engine")
struct BackendParityHarnessProbeTests {
    private typealias Harness = BackendParityHarness

    private let seed = [1, 2, 3, 4, 5]

    private func serving(
        packed: Bool = false,
        vision: Bool = false
    ) -> BackendParityHarness.ServingModel {
        BackendParityHarness.ServingModel(
            model: ParityProbeStubModel(),
            tokenizer: ParityProbeTokenizer(template: nil),
            claimsPackedPrefill: packed,
            claimsVisionSpans: vision,
            typeName: "StubServingModel",
            spanEmbedding: nil)
    }

    private func box(_ engine: ScriptedBenchmarkEngine) -> BackendParityHarness.EngineBox {
        BackendParityHarness.EngineBox(
            engine: engine, kind: .paged, fallbackReason: nil, pagedPoolDType: "float16")
    }

    private func container() -> ModelContainer {
        ModelContainer(
            context: ModelContext(
                configuration: ModelConfiguration(id: "test/parity-probe-stub"),
                model: ParityProbeStubModel(),
                processor: ParityProbeProcessor(),
                tokenizer: ParityProbeTokenizer(template: nil)))
    }

    /// Replies with tokens derived from the prompt alone, so a solo run and
    /// a concurrent run of the same prompt agree.
    private func promptEchoEngine(
        packedActivity: [CBv2PackedPrefillActivity]
    ) -> ScriptedBenchmarkEngine {
        ScriptedBenchmarkEngine(packedActivity: packedActivity) { request in
            .events([
                scriptedDelta([request.promptTokens[0], request.promptTokens.count]),
                scriptedFinish(.length),
            ], gap: .zero)
        }
    }

    // MARK: - Pure helpers

    @Test("configuration defaults match the documented probe sizes")
    func configurationDefaults() {
        let defaults = Harness.Configuration()
        #expect(defaults.maxTokens == 48)
        #expect(defaults.packedProbeRows == 3)
        #expect(defaults.packedProbePromptTokens == 192)
        #expect(defaults.prefixProbePromptTokens == 28672)
        #expect(defaults.visionSpanTokens == 8)
        #expect(defaults.kvBytesCapacity == nil)

        let custom = Harness.Configuration(
            maxTokens: 4, packedProbeRows: 2, packedProbePromptTokens: 16,
            prefixProbePromptTokens: 512, visionSpanTokens: 1, kvBytesCapacity: 1024)
        #expect(custom.maxTokens == 4)
        #expect(custom.packedProbeRows == 2)
        #expect(custom.packedProbePromptTokens == 16)
        #expect(custom.prefixProbePromptTokens == 512)
        #expect(custom.visionSpanTokens == 1)
        #expect(custom.kvBytesCapacity == 1024)
    }

    @Test("the pool dtype is pinned to fp16 and a probe override wins")
    func engineEnvironmentPrecedence() {
        let ambient = ["DARKBLOOM_CBV2_PAGED_KV_DTYPE": "float32", "OTHER": "kept"]
        #expect(Harness.engineEnvironment(ambient: ambient, overrides: [:]) == [
            "DARKBLOOM_CBV2_PAGED_KV_DTYPE": "float16", "OTHER": "kept",
        ])
        #expect(Harness.engineEnvironment(
            ambient: ambient,
            overrides: ["DARKBLOOM_CBV2_PAGED_KV_DTYPE": "float32", "EXTRA": "1"]
        ) == ["DARKBLOOM_CBV2_PAGED_KV_DTYPE": "float32", "OTHER": "kept", "EXTRA": "1"])
        #expect(Harness.pinnedPoolDTypeEnvironment == ["DARKBLOOM_CBV2_PAGED_KV_DTYPE": "float16"])
    }

    @Test("short names trim whitespace and cut long prompts to 40 characters")
    func shortNames() {
        #expect(Harness.shortName("  List three prime numbers.  ") == "List three prime numbers.")
        let forty = String(repeating: "a", count: 40)
        #expect(Harness.shortName(forty) == forty)
        let long = String(repeating: "b", count: 41)
        #expect(Harness.shortName(long) == String(repeating: "b", count: 37) + "...")
        #expect(Harness.parityPrompts.count == 3)
        #expect(Harness.parityPrompts.map { Harness.shortName($0).count }.max() == 40)
    }

    @Test("finish reasons and prefix outcomes use the report vocabulary")
    func describeVocabulary() {
        #expect(Harness.describe(CBv2FinishReason.stop) == "stop")
        #expect(Harness.describe(CBv2FinishReason.length) == "length")
        #expect(Harness.describe(CBv2FinishReason.cancelled) == "cancelled")
        #expect(Harness.describe(CBv2FinishReason.error("boom")) == "error(boom)")
        #expect(Harness.describe(CBv2FinishReason.terminal(cause: .decodeStall, message: "late"))
            == "terminal(decodeStall)")
        #expect(Harness.describe(CBv2PrefixCacheOutcome.disabled) == "disabled")
        #expect(Harness.describe(CBv2PrefixCacheOutcome.skippedPolicy) == "skipped_policy")
        #expect(Harness.describe(CBv2PrefixCacheOutcome.miss) == "miss")
        #expect(Harness.describe(CBv2PrefixCacheOutcome.hit) == "hit")
        #expect(Harness.describe(CBv2PrefixCacheOutcome.skippedCapacity) == "skipped_capacity")
        #expect(Harness.describe(CBv2PrefixCacheOutcome.adoptionFailed) == "adoption_failed")
        #expect(Harness.cleanTerminals == ["stop", "length"])
    }

    @Test("parity prompts use the chat template and fall back to raw text without one")
    func chatPromptTokens() {
        let templated = Harness.chatPromptTokens(
            tokenizer: ParityProbeTokenizer(template: [9, 8, 7]), text: "hello")
        #expect(templated == [9, 8, 7])
        let throwing = Harness.chatPromptTokens(
            tokenizer: ParityProbeTokenizer(template: nil), text: "hello")
        #expect(throwing == [5, 1])
        let empty = Harness.chatPromptTokens(
            tokenizer: ParityProbeTokenizer(template: []), text: "hi")
        #expect(empty == [2, 1])
    }

    @Test("notes name resolved and requested backends and flag a VLM checkpoint")
    func notes() {
        let baseline = BackendParityObservation(
            selection: "contiguous", resolvedBackend: "contiguous")
        let candidate = BackendParityObservation(
            selection: "paged", resolvedBackend: "contiguous", fallbackReason: "kill switch")
        let text = Harness.makeNotes(baseline: baseline, candidate: candidate, isVLM: false)
        #expect(text.count == 3)
        #expect(text[0] == "verdicts describe the RESOLVED backends (contiguous vs contiguous "
            + "(fallback: kill switch)), not the requested selections (contiguous vs paged).")
        #expect(!text[1].contains("VLM"))
        #expect(text[2].hasPrefix("token comparisons are over RAW SAMPLED TOKEN IDS"))
        let vlm = Harness.makeNotes(baseline: baseline, candidate: candidate, isVLM: true)
        #expect(vlm[1].hasSuffix("This checkpoint IS a VLM and is served here through the "
            + "wrapper's directly owned shared text tower."))
    }

    // MARK: - Generation

    @Test("generation keeps raw token ids and the top-two logprob margins")
    func generateCollectsMargins() async throws {
        let engine = ScriptedBenchmarkEngine { _ in
            .events([
                .delta(text: "a", tokens: [5], logprobs: [CBv2TokenLogprob(
                    token: 5, logprob: -0.5,
                    topLogprobs: [(token: 5, logprob: -0.5), (token: 7, logprob: -2.0)])]),
                .delta(text: "b", tokens: [6], logprobs: [CBv2TokenLogprob(
                    token: 6, logprob: -0.25, topLogprobs: [(token: 6, logprob: -0.25)])]),
                scriptedDelta([8]),
                scriptedFinish(.stop),
            ], gap: .zero)
        }
        let row = await Harness.generate(
            engine: engine, id: 9, name: "row", tokens: [1, 2], maxTokens: 4, eos: [2],
            topLogprobs: 2)
        #expect(row == BackendParityObservation.Row(
            prompt: "row", tokens: [5, 6, 8], finishReason: "stop", margins: [1.5]))

        let request = try #require(engine.requests.first)
        #expect(request.id.raw == 9)
        #expect(request.promptTokens == [1, 2])
        #expect(request.maxTokens == 4)
        #expect(request.stopTokens == [2])
        #expect(request.sampling.temperature == 0)
        #expect(request.sampling.topLogprobs == 2)
        #expect(!request.prefixCacheEnabled)
        #expect(request.multimodal == nil)
    }

    @Test("generation reports a missing terminal and a submit refusal as finish reasons")
    func generateFailures() async {
        let open = ScriptedBenchmarkEngine { _ in .events([scriptedDelta([3])], gap: .zero) }
        let unterminated = await Harness.generate(
            engine: open, id: 1, name: "open", tokens: [1], maxTokens: 2, eos: [])
        #expect(unterminated == BackendParityObservation.Row(
            prompt: "open", tokens: [3], finishReason: "unterminated"))

        let refusing = ScriptedBenchmarkEngine { _ in .refuse("pool full") }
        let refused = await Harness.generate(
            engine: refusing, id: 2, name: "refused", tokens: [1], maxTokens: 2, eos: [])
        #expect(refused == BackendParityObservation.Row(
            prompt: "refused", tokens: [], finishReason: "submit_error: pool full"))
    }

    @Test("generation with usage enables the prefix cache and returns the terminal usage")
    func generateWithUsage() async throws {
        let engine = ScriptedBenchmarkEngine { _ in
            .events([
                scriptedDelta([4]),
                .finished(reason: .length, usage: CBv2Usage(
                    promptTokens: 3, completionTokens: 1, prefixCacheOutcome: .hit,
                    prefixCacheMatchedTokens: 256)),
            ], gap: .zero)
        }
        let result = await Harness.generateWithUsage(
            engine: engine, id: 4001, name: "prefix-1", tokens: [1, 2, 3], maxTokens: 1,
            eos: [9])
        #expect(result.row == BackendParityObservation.Row(
            prompt: "prefix-1", tokens: [4], finishReason: "length"))
        #expect(result.usage?.prefixCacheOutcome == .hit)
        #expect(result.usage?.prefixCacheMatchedTokens == 256)
        let request = try #require(engine.requests.first)
        #expect(request.prefixCacheEnabled)
        #expect(request.stopTokens == [9])

        let refusing = ScriptedBenchmarkEngine { _ in .refuse("no seats") }
        let refused = await Harness.generateWithUsage(
            engine: refusing, id: 4002, name: "prefix-2", tokens: [1], maxTokens: 1, eos: [])
        #expect(refused.row.finishReason == "submit_error: no seats")
        #expect(refused.row.tokens.isEmpty)
        #expect(refused.usage == nil)

        let unterminated = ScriptedBenchmarkEngine { _ in .events([], gap: .zero) }
        let empty = await Harness.generateWithUsage(
            engine: unterminated, id: 4003, name: "prefix-3", tokens: [1], maxTokens: 1, eos: [])
        #expect(empty.row.finishReason == "unterminated")
        #expect(empty.usage == nil)
    }

    // MARK: - Packed prefill probe

    @Test("packed prefill is a model fact when the model does not claim it")
    func packedPrefillUnclaimed() async {
        let engine = promptEchoEngine(packedActivity: [])
        let capability = await Harness.probePackedPrefill(
            box: box(engine), serving: serving(packed: false), seed: seed, eos: [],
            configuration: .init(maxTokens: 2))
        #expect(capability.active == nil)
        #expect(capability.detail.hasPrefix("model StubServingModel does not claim"))
        #expect(engine.requests.isEmpty)
    }

    @Test("packed prefill is active when rows match solo and a packed forward ran")
    func packedPrefillActive() async {
        let engine = promptEchoEngine(packedActivity: [
            CBv2PackedPrefillActivity(isSupported: true, rowsExecuted: 2, groupsExecuted: 1),
            CBv2PackedPrefillActivity(isSupported: true, rowsExecuted: 5, groupsExecuted: 2),
        ])
        let capability = await Harness.probePackedPrefill(
            box: box(engine), serving: serving(packed: true), seed: seed, eos: [],
            configuration: .init(maxTokens: 2, packedProbeRows: 3, packedProbePromptTokens: 8))
        #expect(capability.active == true)
        #expect(capability.detail == "1 rectangular packed forward(s) carrying 3 prompt row(s) "
            + "executed for 3 equal-length concurrent rows, and every row was bit-identical "
            + "to the same prompt run solo")

        let requests = engine.requests
        #expect(requests.count == 6)
        #expect(requests.prefix(3).map(\.id.raw) == [1000, 1001, 1002])
        #expect(requests.dropFirst(3).map(\.id.raw).sorted() == [2000, 2001, 2002])
        for request in requests {
            let index = Int(request.id.raw % 1000)
            #expect(request.promptTokens == ThroughputSweep.tile(seed, to: 8, offset: index * 7 + 1))
            #expect(request.maxTokens == 2)
        }
    }

    @Test("packed prefill fails when concurrent rows diverge from solo rows")
    func packedPrefillDiverges() async {
        let engine = ScriptedBenchmarkEngine(packedActivity: [
            .init(isSupported: true, rowsExecuted: 0, groupsExecuted: 0),
            .init(isSupported: true, rowsExecuted: 3, groupsExecuted: 1),
        ]) { request in
            .events([scriptedDelta([Int(request.id.raw)]), scriptedFinish(.length)], gap: .zero)
        }
        let capability = await Harness.probePackedPrefill(
            box: box(engine), serving: serving(packed: true), seed: seed, eos: [],
            configuration: .init(maxTokens: 1, packedProbeRows: 3, packedProbePromptTokens: 8))
        #expect(capability.active == false)
        #expect(capability.detail.hasPrefix(
            "3 equal-length rows decoded concurrently diverged from the same rows run solo"))
        #expect(capability.detail.contains("(1 packed group(s) over 3 row(s) ran during the batch)"))
    }

    @Test("packed prefill is inactive when the cache refuses or nothing packed")
    func packedPrefillInactive() async {
        let refused = promptEchoEngine(packedActivity: [
            .init(isSupported: false, rowsExecuted: 0, groupsExecuted: 0),
        ])
        let unsupported = await Harness.probePackedPrefill(
            box: box(refused), serving: serving(packed: true), seed: seed, eos: [],
            configuration: .init(maxTokens: 1, packedProbeRows: 1, packedProbePromptTokens: 3))
        #expect(unsupported.active == false)
        #expect(unsupported.detail.contains("isSupported=false"))
        // The probe raises the row count to 2 and the prompt length to 8.
        #expect(refused.requests.count == 4)
        #expect(refused.requests.allSatisfy { $0.promptTokens.count == 8 })

        let idle = promptEchoEngine(packedActivity: [
            .init(isSupported: true, rowsExecuted: 4, groupsExecuted: 2),
        ])
        let neverRan = await Harness.probePackedPrefill(
            box: box(idle), serving: serving(packed: true), seed: seed, eos: [],
            configuration: .init(maxTokens: 1, packedProbeRows: 2, packedProbePromptTokens: 8))
        #expect(neverRan.active == false)
        #expect(neverRan.detail.hasPrefix("packed prefill is supported but NEVER EXECUTED: 2 "))
    }

    // MARK: - Vision, numerics control and MTP early outcomes

    @Test("vision spans are undetermined without a model claim or a span embedding")
    func visionSpansUndetermined() async {
        let engine = promptEchoEngine(packedActivity: [])
        let unclaimed = await Harness.probeVisionSpans(
            box: box(engine), serving: serving(vision: false), seed: seed, eos: [],
            configuration: .init())
        #expect(unclaimed.active == nil)
        #expect(unclaimed.detail.hasPrefix(
            "model StubServingModel reports supportsVisionSpanPrefill=false"))

        let noEmbedding = await Harness.probeVisionSpans(
            box: box(engine), serving: serving(vision: true), seed: seed, eos: [],
            configuration: .init())
        #expect(noEmbedding == .undetermined(
            "model claims vision-span prefill but no span embedding could be built from "
                + "scaledInputEmbeddings"))
        #expect(engine.requests.isEmpty)
    }

    @Test("the numerics control refuses a candidate that served no paged rows")
    func numericsControlNeedsPagedRows() async {
        let perturbation = "paged pool dtype float16 -> float32"
        let cases: [(BackendParityObservation, String, String?)] = [
            (BackendParityObservation(selection: "paged", resolvedBackend: "contiguous"),
             "resolved contiguous, 0 rows", nil),
            (BackendParityObservation(selection: "paged", constructionFailure: "refused"),
             "resolved nothing, 0 rows", nil),
            (BackendParityObservation(
                selection: "paged", resolvedBackend: "paged", pagedPoolDType: "float16"),
             "resolved paged, 0 rows", "float16"),
        ]
        for (candidate, summary, dtype) in cases {
            let control = await Harness.probeNumericsControl(
                container: container(), serving: serving(), candidate: candidate,
                kvCapacity: 0, facts: (eos: [], prompts: []), configuration: .init())
            #expect(control == BackendParityReport.NumericsControl(
                perturbation: perturbation, tokenExact: nil,
                detail: "the candidate arm did not serve paged rows (\(summary)), so there "
                    + "is nothing to perturb",
                candidatePoolDType: dtype))
        }
    }

    @Test("the MTP probe reports why no drafter is available")
    func mtpWithoutDrafter() async {
        let supplied = await Harness.probeMTP(
            container: container(), serving: serving(), selection: .paged, kvCapacity: 0,
            prompts: [], eos: [], drafter: nil,
            drafterFailure: "no MTP assistant supplied (--assistant-model)",
            configuration: .init())
        #expect(supplied == BackendParityObservation.MTP(
            unavailableReason: "no MTP assistant supplied (--assistant-model)"))

        let unnamed = await Harness.probeMTP(
            container: container(), serving: serving(), selection: .contiguous, kvCapacity: 0,
            prompts: [], eos: [], drafter: nil, drafterFailure: nil, configuration: .init())
        #expect(unnamed?.unavailableReason == "no drafter")
        #expect(unnamed?.producedDrafts == false)
    }
}
