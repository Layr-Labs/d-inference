// Copyright © 2026 Eigen Labs.
//
// Teacher-forced contiguous-vs-paged agreement gate (live, operator-run).
//
// Free-running greedy comparison decorrelates after the first flip, so this
// suite feeds every arm the SAME token sequence and scores each step's argmax
// against an identical context. `EngineV2PagedParityLiveTests` delegates its
// gemma-4 agreement floor here.
//
// Gated OFF by default. Run with:
//   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_PAGED_DIVERGENCE_PROBE=1 \
//     swift test --filter PagedTeacherForcedAgreementTests

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

/// Loads a live checkpoint and steps it through an arbitrary per-layer mix of
/// the paged and contiguous KV backends at the layer-cache seam (no engine,
/// no scheduler, no sampler), capturing the full logit vector at every step.
struct PagedAgreementHarness {

    private static let gib = 1024 * 1024 * 1024

    // MARK: - Measurement types

    struct StepLogits {
        let id: Int
        let values: [Float]
    }

    /// One decode trajectory: `steps` greedy tokens plus the full logit
    /// vector that produced each one.
    struct Trajectory {
        let label: String
        let steps: [StepLogits]
        var ids: [Int] { steps.map(\.id) }
    }

    // MARK: - Stepping

    /// Prefill `prompt`, then greedily decode `steps` tokens, returning the
    /// full logit vector behind every sampled id.
    ///
    /// `usePaged(layer)` picks the backend PER LAYER, which is what makes the
    /// localization sweep possible: both banks accept an arbitrary mix of
    /// `CBv2AttendingLayerCache`s, and each layer's row storage is bound
    /// independently, so a hybrid bank is a legal engine configuration and
    /// not a test-only fiction.
    func trajectory(
        label: String,
        model: any LanguageModel,
        kinds: [CBv2LayerKind],
        prompt: [Int],
        steps: Int,
        paged: PagedKVBackend,
        contiguous: CBv2ContiguousKVBackend,
        /// When set, the arm is fed THESE tokens instead of its own argmax, so
        /// every step is scored against an identical context and the
        /// comparison cannot decorrelate after a single flip.
        forced: [Int]? = nil,
        usePaged: (Int) -> Bool
    ) throws -> Trajectory {
        let maxLength = prompt.count + steps + 2
        let pagedRows = try paged.makeSequenceState(
            layerKinds: kinds, promptLength: prompt.count, maxLength: maxLength)
        let contigRows = try contiguous.makeSequenceState(
            layerKinds: kinds, promptLength: prompt.count, maxLength: maxLength)
        defer {
            paged.release(pagedRows)
            contiguous.release(contigRows)
        }

        let pagedCaches = paged.makeLayerCaches()
        var caches: [any CBv2AttendingLayerCache] = []
        var rows: [CBv2SequenceKV?] = []
        caches.reserveCapacity(kinds.count)
        rows.reserveCapacity(kinds.count)
        for (index, kind) in kinds.enumerated() {
            if usePaged(index) {
                caches.append(pagedCaches[index])
                rows.append(pagedRows[index])
            } else {
                caches.append(
                    CBv2LayerCache(layerIndex: index, kind: kind, attentionSoftcap: nil))
                rows.append(contigRows[index])
            }
        }

        let bank = CBv2LayerCacheBank(caches: caches)
        let adapter = CBv2SteppableLanguageModelAdapter(model)

        var out: [StepLogits] = []
        out.reserveCapacity(steps)
        var input = MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count])
        for _ in 0 ..< steps {
            let bound = bank.layerCaches(rowStates: [rows])
            let logits = adapter.forward(tokens: input, caches: bound)
            let row = logits[0..., -1, 0...].reshaped([-1]).asType(.float32)
            eval(row)
            let values = row.asArray(Float.self)
            var best = 0
            for candidate in 1 ..< values.count where values[candidate] > values[best] {
                best = candidate
            }
            out.append(StepLogits(id: best, values: values))
            let next = forced.map { $0[out.count - 1] } ?? best
            input = MLXArray([Int32(next)]).reshaped([1, 1])
        }
        return Trajectory(label: label, steps: out)
    }

    // MARK: - Model loading

    struct Loaded {
        let serving: any LanguageModel
        let kinds: [CBv2LayerKind]
        let prompts: [(name: String, tokens: [Int])]
    }

    func load(
        modelID: String, isVLM: Bool, budget: Int, prompts: [String]
    ) async throws -> Loaded {
        guard LiveInferenceFixtures.ensureMetallibColocated() != nil else {
            throw LiveFixtureSkip.missingMetallib
        }
        guard case .found(let directory) = LiveInferenceFixtures.locate(modelID) else {
            throw LiveFixtureSkip.modelNotInCache(modelID)
        }
        LiveInferenceFixtures.applyMemoryBudget(maxBytes: budget)
        let container: ModelContainer =
            isVLM
            ? try await VLMModelFactory.shared.loadContainer(
                from: directory, using: LocalTokenizerLoader())
            : try await LLMModelFactory.shared.loadContainer(
                from: directory, using: LocalTokenizerLoader())

        struct Box: @unchecked Sendable {
            let serving: any LanguageModel
            let kinds: [CBv2LayerKind]
            let prompts: [(name: String, tokens: [Int])]
        }
        let box = try await container.perform { ctx -> Box in
            let serving = try EngineV2Factory.benchmarkServingModel(
                model: ctx.model, isVLM: isVLM, modelDirectory: directory)
            guard let kinds = EngineV2Factory.cbv2LayerKinds(model: serving) else {
                throw LiveFixtureSkip.modelNotInCache("no cbv2 layer kinds for \(modelID)")
            }
            // GPT-OSS primes its sinks-activation probe inside newCacheV2;
            // build one throwaway bank so the probe is armed exactly as a
            // production build would arm it.
            if let gptoss = serving as? GPTOSSModel {
                _ = gptoss.newCacheV2 { index, kind in
                    CBv2LayerCache(layerIndex: index, kind: kind, attentionSoftcap: nil)
                }
            }
            let encoded = prompts.map {
                (name: String($0.prefix(28)), tokens: ctx.tokenizer.encode(text: $0))
            }
            return Box(serving: serving, kinds: kinds, prompts: encoded)
        }
        return Loaded(serving: box.serving, kinds: box.kinds, prompts: box.prompts)
    }

    func makePagedBackend(kinds: [CBv2LayerKind], dtype: DType) throws -> PagedKVBackend {
        try PagedKVBackend(
            layerKinds: kinds,
            config: PagedKVPoolConfig(
                capacityBytes: 512 * 1024 * 1024,
                dtype: dtype,
                maxPrefillChunk: 512,
                nominalMaxSequenceLength: 2048))
    }

    func makeContiguousBackend() -> CBv2ContiguousKVBackend {
        CBv2ContiguousKVBackend(
            config: CBv2ContiguousBackendConfig(bytesCapacity: 3 * Self.gib))
    }
}

// MARK: - Teacher-forced agreement

/// The replacement gate (measurement AND assertion — see the per-model
/// floors in `agreementRates`; the dark path with the env vars unset stays
/// an early return that asserts nothing).
///
/// Free-running greedy comparison is a bad instrument: after ONE flip the two
/// arms are reading different contexts, so every later step is comparing two
/// unrelated conversations and the "number of differing tokens" says nothing
/// about the backend. TEACHER FORCING removes that: both arms are fed the
/// SAME token sequence and each step's argmax is scored against an identical
/// context, so the per-step agreement rate is a real statistic about the
/// backend rather than about how early it first diverged.
///
/// Three arms are scored against the contiguous baseline so the candidate has
/// a CONTROL to be judged against, not an absolute threshold pulled from air:
///   * contiguous re-run  — must be 100%; anything less means the harness is
///     nondeterministic and no comparison is meaningful.
///   * paged fp32 pages   — the same paged code path at a different compute
///     precision. Two equally valid evaluations of ONE backend, so its
///     agreement rate is the ceiling any cross-backend comparison can reach.
///   * paged fp16 pages   — the shipping candidate.
@Suite("paged teacher-forced agreement (live)", .serialized)
struct PagedTeacherForcedAgreementTests {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
            && ProcessInfo.processInfo.environment["DARKBLOOM_PAGED_DIVERGENCE_PROBE"] != nil
    }

    private static let prompts = [
        "List three prime numbers.",
        "Explain, in two sentences, why the sky appears blue on a clear day.",
        "Summarize the tradeoffs between contiguous and paged key-value cache "
            + "layouts for transformer inference on unified-memory hardware, "
            + "covering memory waste, admission, and kernel dispatch overhead.",
        "What is the capital of France?",
        "Write a haiku about winter mornings.",
        "Translate to French: the library closes at six.",
        "Give me a one-line definition of entropy.",
        "Name the four inner planets of the solar system.",
        "How does a binary search work?",
        "Why do leaves change colour in autumn?",
        "State Newton's second law.",
        "What is the difference between a list and a tuple in Python?",
    ]

    @Test("teacher-forced top-1 agreement, candidate vs control arms")
    func agreementRates() async throws {
        guard Self.enabled else { return }
        let harness = PagedAgreementHarness()
        // `candidateFloor` is the per-model gate on the paged-fp16 candidate
        // arm, in percent agreement. Calibration (2026-07, M4 Max 128 GB,
        // this exact harness):
        //   * gpt-oss measured 100.00% — clean, so it is pinned EXACT: any
        //     flip on gpt-oss is new behavior and must fail.
        //   * gemma-4 measured 91.15% — the accepted cross-backend drift
        //     (equally-valid fp16 evaluations disagreeing at near-ties,
        //     amplified by 30 layers of top-8-of-128 MoE routing; see the
        //     margin statistics this test prints). The 88% floor sits below
        //     the measured drift band and catches only GROSS regression
        //     (wrong key set, broken gather, corrupted pages — failure modes
        //     that measured orders of magnitude worse in the 2026-07
        //     planted-bug calibration of the paged decode kernel).
        // DO NOT "tighten" the gemma floor toward 91%: the calibration
        // finding is that subtle real bugs present BELOW the drift band —
        // they are not catchable by this statistic at any threshold — so a
        // tighter floor buys no bug-detection, only a gate that flaps
        // whenever legitimate drift wanders a point.
        for (modelID, isVLM, budget, candidateFloor) in [
            ("mlx-community/gemma-4-26B-A4B-it-qat-4bit", true, 72, 88.0),
            ("mlx-community/gpt-oss-20b-MXFP4-Q8", false, 48, 100.0),
        ] {
            let live = try await harness.load(
                modelID: modelID, isVLM: isVLM, budget: budget * 1024 * 1024 * 1024,
                prompts: Self.prompts)
            let kinds = live.kinds
            let steps = 16
            let contiguous = harness.makeContiguousBackend()
            let pagedFP16 = try harness.makePagedBackend(kinds: kinds, dtype: .float16)
            let pagedFP32 = try harness.makePagedBackend(kinds: kinds, dtype: .float32)

            var totals: [String: (agree: Int, total: Int)] = [:]
            var firstFlip: [String: [Int]] = [:]
            // Baseline top-2 margin at every scored position, split by whether
            // the arm flipped there. If flips are drift landing on near-ties,
            // the flipped set is drawn from the LOW-margin tail and the agreed
            // set is not.
            var marginFlipped: [String: [Float]] = [:]
            var marginAgreed: [String: [Float]] = [:]
            var flipPositions: [String: Set<String>] = [:]

            for (name, prompt) in live.prompts {
                let base = try harness.trajectory(
                    label: "contiguous", model: live.serving, kinds: kinds, prompt: prompt,
                    steps: steps, paged: pagedFP16, contiguous: contiguous, forced: nil,
                    usePaged: { _ in false })
                let forced = base.ids
                let margins: [Float] = base.steps.map { step in
                    var top1: Float = -.greatestFiniteMagnitude
                    var top2: Float = -.greatestFiniteMagnitude
                    for value in step.values {
                        if value > top1 {
                            top2 = top1
                            top1 = value
                        } else if value > top2 {
                            top2 = value
                        }
                    }
                    return top1 - top2
                }
                MLX.Memory.clearCache()

                for (label, arm) in [
                    ("contiguous-rerun", { (f: [Int]) in
                        try harness.trajectory(
                            label: "c2", model: live.serving, kinds: kinds, prompt: prompt,
                            steps: steps, paged: pagedFP16, contiguous: contiguous, forced: f,
                            usePaged: { _ in false })
                    }),
                    ("paged-fp32(control)", { (f: [Int]) in
                        try harness.trajectory(
                            label: "p32", model: live.serving, kinds: kinds, prompt: prompt,
                            steps: steps, paged: pagedFP32, contiguous: contiguous, forced: f,
                            usePaged: { _ in true })
                    }),
                    ("paged-fp16(candidate)", { (f: [Int]) in
                        try harness.trajectory(
                            label: "p16", model: live.serving, kinds: kinds, prompt: prompt,
                            steps: steps, paged: pagedFP16, contiguous: contiguous, forced: f,
                            usePaged: { _ in true })
                    }),
                ] {
                    let run = try arm(forced)
                    var agree = 0
                    var flip = steps
                    for step in 0 ..< steps {
                        if run.ids[step] == forced[step] {
                            agree += 1
                            marginAgreed[label, default: []].append(margins[step])
                        } else {
                            if flip == steps { flip = step }
                            marginFlipped[label, default: []].append(margins[step])
                            flipPositions[label, default: []].insert("\(name)#\(step)")
                        }
                    }
                    let prior = totals[label] ?? (0, 0)
                    totals[label] = (prior.agree + agree, prior.total + steps)
                    firstFlip[label, default: []].append(flip)
                    MLX.Memory.clearCache()
                }
            }
            print("[tf] ===== \(modelID) =====")
            for label in ["contiguous-rerun", "paged-fp32(control)", "paged-fp16(candidate)"] {
                guard let t = totals[label] else { continue }
                let flips = firstFlip[label] ?? []
                let clean = flips.filter { $0 == steps }.count
                print(
                    String(
                        format:
                            "[tf] %-22@ agreement %4d/%4d = %6.2f%%   prompts with zero flips %d/%d",
                        label, t.agree, t.total, 100.0 * Double(t.agree) / Double(t.total),
                        clean, flips.count))
                let flipped = (marginFlipped[label] ?? []).sorted()
                let agreed = (marginAgreed[label] ?? []).sorted()
                func pct(_ xs: [Float], _ p: Double) -> Float {
                    guard !xs.isEmpty else { return .nan }
                    return xs[min(xs.count - 1, Int(p * Double(xs.count)))]
                }
                print(
                    String(
                        format:
                            "[tf]   baseline top-2 margin | flipped n=%d p50=%.3f p90=%.3f max=%.3f"
                            + " | agreed n=%d p50=%.3f p10=%.3f min=%.3f",
                        flipped.count, pct(flipped, 0.5), pct(flipped, 0.9),
                        flipped.last ?? .nan,
                        agreed.count, pct(agreed, 0.5), pct(agreed, 0.1),
                        agreed.first ?? .nan))
            }
            let a = flipPositions["paged-fp16(candidate)"] ?? []
            let b = flipPositions["paged-fp32(control)"] ?? []
            print(
                "[tf]   flip-position overlap fp16 vs fp32: \(a.intersection(b).count)"
                    + " of \(a.count)/\(b.count) — identical set: \(a == b)")

            // ==== THE GATE (v0.8.0 audit): measure AND assert. ====
            // This test used to print the three agreement rates and assert
            // nothing — a 0%-agreement paged backend would have exited green.
            func agreementPercent(_ label: String) -> Double {
                guard let t = totals[label], t.total > 0 else { return -1 }
                return 100.0 * Double(t.agree) / Double(t.total)
            }
            let controlRate = agreementPercent("contiguous-rerun")
            let candidateRate = agreementPercent("paged-fp16(candidate)")

            // Control arm first: the same backend re-scored against its own
            // forced tokens. Anything under 100% means the HARNESS is
            // nondeterministic and neither number below says anything about
            // the paged backend — fail on the instrument, loudly, so a bad
            // candidate reading is never trusted or "explained".
            #expect(
                controlRate == 100.0,
                "\(modelID): contiguous-rerun control scored \(controlRate)% (want exactly 100%) — the harness is nondeterministic and every arm's rate is meaningless")

            #expect(
                candidateRate >= candidateFloor,
                "\(modelID): paged-fp16 candidate teacher-forced agreement \(candidateRate)% fell below the \(candidateFloor)% floor (gpt-oss calibrated 100.00% exact; gemma-4 calibrated 91.15% with accepted drift) — gross paged regression")
            MLX.Memory.clearCache()
        }
    }
}
