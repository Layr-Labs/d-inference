// Copyright © 2026 Eigen Labs.
//
// P1 INVESTIGATION PROBE (temporary, operator-run): quantify the gemma-4
// paged-vs-contiguous greedy token divergence that `darkbloom benchmark
// --parity` reports as `token_exactness FAIL`.
//
// The harness only ever sees SAMPLED IDS, so "token 1 differs" is all it can
// say. This probe drives the same weights through the same two backends at
// the LAYER-CACHE seam (no engine, no scheduler, no sampler) and captures the
// FULL logit vector at each decode step, so the question "is the winner's
// margin inside or outside the cross-backend perturbation" can be answered
// numerically instead of asserted.
//
// It also runs the three discriminating A/Bs the verdict depends on:
//   * paged pool at .float32 instead of .float16  -> is it storage dtype?
//   * paged ring forced back to 97 pages          -> did this wave cause it?
//   * paged on exactly ONE layer at a time        -> which layer seeds it?
//
// Gated OFF by default. Run with:
//   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_PAGED_DIVERGENCE_PROBE=1 \
//     swift test --filter PagedDivergenceProbeTests

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import Testing

@testable import ProviderCore

@Suite("paged divergence probe (live)", .serialized)
struct PagedDivergenceProbeTests {

    private static let gemmaID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    private static let gptossID = "mlx-community/gpt-oss-20b-MXFP4-Q8"
    private static let gib = 1024 * 1024 * 1024

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
            && ProcessInfo.processInfo.environment["DARKBLOOM_PAGED_DIVERGENCE_PROBE"] != nil
    }

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

    // MARK: - Probe core

    /// Prefill `prompt`, then greedily decode `steps` tokens, returning the
    /// full logit vector behind every sampled id.
    ///
    /// `usePaged(layer)` picks the backend PER LAYER, which is what makes the
    /// localization sweep possible: both banks accept an arbitrary mix of
    /// `CBv2AttendingLayerCache`s, and each layer's row storage is bound
    /// independently, so a hybrid bank is a legal engine configuration and
    /// not a test-only fiction.
    private func trajectory(
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

    // MARK: - Reporting

    private func topK(_ values: [Float], _ k: Int) -> [(id: Int, value: Float)] {
        var idx = Array(values.indices)
        idx.sort { values[$0] > values[$1] }
        return idx.prefix(k).map { (id: $0, value: values[$0]) }
    }

    /// The whole verdict in one line per step.
    ///
    /// `margin` is the top-1 minus top-2 gap on each arm — the distance the
    /// argmax had to travel to flip. `maxDelta` is the largest cross-backend
    /// logit perturbation anywhere in the vocabulary. `margin < maxDelta`
    /// means the flip is inside the noise the two kernels already disagree
    /// by, i.e. token exactness is measuring a coin toss.
    @discardableResult
    private func compare(
        _ baseline: Trajectory, _ candidate: Trajectory, tag: String
    ) -> Int? {
        print("[probe] === \(tag): \(baseline.label) vs \(candidate.label) ===")
        print("[probe]   ids base=\(baseline.ids)")
        print("[probe]   ids cand=\(candidate.ids)")
        var firstDivergence: Int?
        let n = min(baseline.steps.count, candidate.steps.count)
        for step in 0 ..< n {
            let a = baseline.steps[step]
            let b = candidate.steps[step]
            var maxDelta: Float = 0
            var argMaxDelta = 0
            for i in 0 ..< min(a.values.count, b.values.count) {
                let d = abs(a.values[i] - b.values[i])
                if d > maxDelta {
                    maxDelta = d
                    argMaxDelta = i
                }
            }
            let ta = topK(a.values, 5)
            let tb = topK(b.values, 5)
            let marginA = ta[0].value - ta[1].value
            let marginB = tb[0].value - tb[1].value
            // Perturbation restricted to the two candidates that actually
            // competed — the only deltas that can flip this argmax.
            let contested = Set([ta[0].id, ta[1].id, tb[0].id, tb[1].id])
            var contestedDelta: Float = 0
            for id in contested {
                contestedDelta = max(contestedDelta, abs(a.values[id] - b.values[id]))
            }
            let flipped = a.id != b.id
            if flipped, firstDivergence == nil { firstDivergence = step }
            print(
                "[probe]   step \(step) \(flipped ? "DIVERGE" : "match  ")"
                    + " base=\(a.id) cand=\(b.id)"
                    + String(
                        format: "  maxΔ=%.5f@%d contestedΔ=%.5f marginBase=%.5f marginCand=%.5f",
                        maxDelta, argMaxDelta, contestedDelta, marginA, marginB))
            if flipped || step == 0 {
                print("[probe]     base top5: " + ta.map { String(format: "%d:%.4f", $0.id, $0.value) }.joined(separator: " "))
                print("[probe]     cand top5: " + tb.map { String(format: "%d:%.4f", $0.id, $0.value) }.joined(separator: " "))
            }
        }
        print("[probe]   firstDivergence=\(firstDivergence.map(String.init) ?? "none")")
        return firstDivergence
    }

    /// Largest cross-arm logit perturbation at `step`, ignoring which token won.
    private func maxDelta(_ a: Trajectory, _ b: Trajectory, step: Int) -> Float {
        guard step < a.steps.count, step < b.steps.count else { return .nan }
        let x = a.steps[step].values
        let y = b.steps[step].values
        var m: Float = 0
        for i in 0 ..< min(x.count, y.count) { m = max(m, abs(x[i] - y[i])) }
        return m
    }

    /// Per-layer max |K| and |V| after a contiguous prefill, in the MODEL
    /// dtype (unclipped).
    ///
    /// This separates the two ways fp16 pages can change a value. bf16 -> fp16
    /// is EXACT for magnitudes inside fp16's normal range (fp16 has 10
    /// mantissa bits against bf16's 7), so if every |K|,|V| lands in
    /// [6e-5, 65504] the paged pool is storing the same numbers and only the
    /// arithmetic can differ. An element outside that range is CLIPPED or
    /// FLUSHED — a value corruption, and a genuine bug.
    private func kvMagnitudes(
        model: any LanguageModel,
        kinds: [CBv2LayerKind],
        prompt: [Int],
        contiguous: CBv2ContiguousKVBackend
    ) throws {
        let rows = try contiguous.makeSequenceState(
            layerKinds: kinds, promptLength: prompt.count, maxLength: prompt.count + 2)
        defer { contiguous.release(rows) }
        let caches: [any CBv2AttendingLayerCache] = kinds.enumerated().map {
            CBv2LayerCache(layerIndex: $0.offset, kind: $0.element, attentionSoftcap: nil)
        }
        let bank = CBv2LayerCacheBank(caches: caches)
        let bound = bank.layerCaches(rowStates: [rows])
        let logits = CBv2SteppableLanguageModelAdapter(model)
            .forward(
                tokens: MLXArray(prompt.map { Int32($0) }).reshaped([1, prompt.count]),
                caches: bound)
        eval(logits)

        let fp16Max: Float = 65504
        let fp16MinNormal: Float = 6.104e-5
        var worstK: Float = 0
        var worstV: Float = 0
        var offenders: [String] = []
        for (layer, row) in rows.enumerated() {
            guard let row else { continue }
            let snap = row.snapshot()
            let kMax = MLX.max(MLX.abs(snap.keys.asType(.float32))).item(Float.self)
            let vMax = MLX.max(MLX.abs(snap.values.asType(.float32))).item(Float.self)
            worstK = max(worstK, kMax)
            worstV = max(worstV, vMax)
            if kMax > fp16Max || vMax > fp16Max {
                offenders.append("layer \(layer) OVERFLOWS fp16 (|k|=\(kMax) |v|=\(vMax))")
            }
        }
        print(
            String(
                format:
                    "[probe] KV magnitude over %d layers: max|K|=%.4f max|V|=%.4f "
                    + "(fp16 normal range [%.2e, %.0f])",
                kinds.count, worstK, worstV, fp16MinNormal, fp16Max))
        if offenders.isEmpty {
            print("[probe]   no layer exceeds fp16 range -> bf16->fp16 storage is VALUE-EXACT")
        } else {
            for line in offenders { print("[probe]   \(line)") }
        }
    }

    // MARK: - Model loading

    struct Loaded {
        let serving: any LanguageModel
        let kinds: [CBv2LayerKind]
        let prompts: [(name: String, tokens: [Int])]
    }

    private func load(
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

    private func makePaged(
        kinds: [CBv2LayerKind], dtype: DType = .float16, maxPrefillChunk: Int = 512
    ) throws -> PagedKVBackend {
        try PagedKVBackend(
            layerKinds: kinds,
            config: PagedKVPoolConfig(
                capacityBytes: 512 * 1024 * 1024,
                dtype: dtype,
                maxPrefillChunk: maxPrefillChunk,
                nominalMaxSequenceLength: 2048))
    }

    private func makeContiguous() -> CBv2ContiguousKVBackend {
        CBv2ContiguousKVBackend(
            config: CBv2ContiguousBackendConfig(bytesCapacity: 3 * Self.gib))
    }

    // Non-private seams so `PagedTeacherForcedAgreementTests` can reuse the
    // exact same loading, backend construction and stepping code — the two
    // suites MUST measure the same thing.
    func loadForAgreement(
        modelID: String, isVLM: Bool, budget: Int, prompts: [String]
    ) async throws -> Loaded {
        try await load(modelID: modelID, isVLM: isVLM, budget: budget, prompts: prompts)
    }

    func makePagedBackend(kinds: [CBv2LayerKind], dtype: DType) throws -> PagedKVBackend {
        try makePaged(kinds: kinds, dtype: dtype)
    }

    func makeContiguousBackend() -> CBv2ContiguousKVBackend { makeContiguous() }

    func trajectoryForAgreement(
        label: String, model: any LanguageModel, kinds: [CBv2LayerKind], prompt: [Int],
        steps: Int, paged: PagedKVBackend, contiguous: CBv2ContiguousKVBackend,
        forced: [Int]?, usePaged: (Int) -> Bool
    ) throws -> Trajectory {
        try trajectory(
            label: label, model: model, kinds: kinds, prompt: prompt, steps: steps,
            paged: paged, contiguous: contiguous, forced: forced, usePaged: usePaged)
    }

    // MARK: - Tests

    @Test("gemma-4: logit gap, dtype/ring A-B, and per-layer localization")
    func gemma4Divergence() async throws {
        guard Self.enabled else { return }
        let live = try await load(
            modelID: Self.gemmaID, isVLM: true, budget: 72 * Self.gib,
            prompts: [
                "List three prime numbers.",
                "Summarize the tradeoffs between contiguous and paged key-value cache "
                    + "layouts for transformer inference on unified-memory hardware, "
                    + "covering memory waste, admission, and kernel dispatch overhead.",
                "Explain, in two sentences, why the sky appears blue on a clear day.",
            ])
        let kinds = live.kinds
        let sliding = kinds.indices.filter {
            if case .slidingWindow = kinds[$0].attention { return true }
            return false
        }
        let full = kinds.indices.filter {
            if case .full = kinds[$0].attention { return true }
            return false
        }
        print("[probe] gemma-4 layers=\(kinds.count) sliding=\(sliding.count) full=\(full)")
        print(
            "[probe] ring pages (window 1024, chunk 512) = "
                + "\(CBv2PagedRingGeometry.ringPageCount(window: 1024, pageSize: 16, maxPrefillChunk: 512))")
        print(
            "[probe] ring pages (window 1024, chunk 1552) = "
                + "\(CBv2PagedRingGeometry.ringPageCount(window: 1024, pageSize: 16, maxPrefillChunk: 1552))")

        let steps = 4
        let contiguous = makeContiguous()

        // One pool per geometry, reused across every run: rows are released
        // each time, so the pages return to the free list and 30 isolation
        // runs do not mean 30 slab allocations.
        let pagedFP16 = try makePaged(kinds: kinds)
        let pagedFP32 = try makePaged(kinds: kinds, dtype: .float32)
        let pagedRing97 = try makePaged(kinds: kinds, maxPrefillChunk: 1552)

        var localizeOn: (name: String, prompt: [Int], step: Int)?

        for (name, prompt) in live.prompts {
            print("[probe] ################ prompt '\(name)' tokens=\(prompt.count)")
            try kvMagnitudes(
                model: live.serving, kinds: kinds, prompt: prompt, contiguous: contiguous)
            MLX.Memory.clearCache()

            let base = try trajectory(
                label: "contiguous", model: live.serving, kinds: kinds, prompt: prompt,
                steps: steps, paged: pagedFP16, contiguous: contiguous,
                usePaged: { _ in false })
            MLX.Memory.clearCache()

            // A/B 0 — determinism control. Same backend twice: any delta here
            // is run-to-run nondeterminism, not a backend difference, and the
            // whole comparison would be meaningless.
            let baseAgain = try trajectory(
                label: "contiguous(repeat)", model: live.serving, kinds: kinds, prompt: prompt,
                steps: steps, paged: pagedFP16, contiguous: contiguous,
                usePaged: { _ in false })
            compare(base, baseAgain, tag: "CONTROL determinism")
            MLX.Memory.clearCache()

            // A/B 1 — the reported failure: fp16 pages, 65-page ring.
            let cand = try trajectory(
                label: "paged fp16 ring65", model: live.serving, kinds: kinds, prompt: prompt,
                steps: steps, paged: pagedFP16, contiguous: contiguous, usePaged: { _ in true })
            let divergeAt = compare(base, cand, tag: "MAIN paged vs contiguous")
            MLX.Memory.clearCache()

            // A/B 2 — storage dtype. fp32 pages remove the bf16->fp16 rounding
            // and leave only the kernel difference.
            let candFP32 = try trajectory(
                label: "paged fp32 ring65", model: live.serving, kinds: kinds, prompt: prompt,
                steps: steps, paged: pagedFP32, contiguous: contiguous, usePaged: { _ in true })
            compare(base, candFP32, tag: "AB-DTYPE fp32 pages")
            MLX.Memory.clearCache()

            // A/B 3 — ring geometry. maxPrefillChunk 1552 restores the
            // pre-wave 97-page ring through the production formula; nothing
            // else changes.
            let candRing97 = try trajectory(
                label: "paged fp16 ring97", model: live.serving, kinds: kinds, prompt: prompt,
                steps: steps, paged: pagedRing97, contiguous: contiguous, usePaged: { _ in true })
            compare(base, candRing97, tag: "AB-RING 97 pages (pre-wave geometry)")
            MLX.Memory.clearCache()

            if let divergeAt, localizeOn == nil {
                localizeOn = (name, prompt, divergeAt)
            }
        }

        guard let target = localizeOn else {
            print("[probe] no prompt diverged; nothing to localize")
            return
        }
        let prompt = target.prompt
        let locSteps = target.step + 1
        print("[probe] ################ localizing '\(target.name)' at step \(target.step)")
        let base = try trajectory(
            label: "contiguous", model: live.serving, kinds: kinds, prompt: prompt,
            steps: locSteps, paged: pagedFP16, contiguous: contiguous, usePaged: { _ in false })
        MLX.Memory.clearCache()

        // Kind split: paged on the 25 sliding layers only, then on the 5 full
        // layers only. A divergence that only appears with the sliding layers
        // paged points at the ring/gather path; one that appears with the
        // full layers paged cannot be the ring at all.
        let slidingOnly = try trajectory(
            label: "paged sliding-only", model: live.serving, kinds: kinds, prompt: prompt,
            steps: locSteps, paged: pagedFP16, contiguous: contiguous,
            usePaged: { sliding.contains($0) })
        compare(base, slidingOnly, tag: "LOC sliding layers paged")
        MLX.Memory.clearCache()

        let fullOnly = try trajectory(
            label: "paged full-only", model: live.serving, kinds: kinds, prompt: prompt,
            steps: locSteps, paged: pagedFP16, contiguous: contiguous,
            usePaged: { full.contains($0) })
        compare(base, fullOnly, tag: "LOC full layers paged")
        MLX.Memory.clearCache()

        // Per-layer isolation: exactly one paged layer at a time, so each
        // number is that layer's own contribution with no accumulation.
        print("[probe] --- per-layer isolation (step 0 = prefill, step \(target.step) = flip) ---")
        for layer in kinds.indices {
            let one = try trajectory(
                label: "paged@\(layer)", model: live.serving, kinds: kinds, prompt: prompt,
                steps: locSteps, paged: pagedFP16, contiguous: contiguous,
                usePaged: { $0 == layer })
            let attention = full.contains(layer) ? "full   " : "sliding"
            let d0 = maxDelta(base, one, step: 0)
            let dN = maxDelta(base, one, step: target.step)
            let flip = one.steps[target.step].id != base.steps[target.step].id
            print(
                String(
                    format: "[probe]   layer %2d %@  maxD(step0)=%.5f  maxD(step%d)=%.5f  %@",
                    layer, attention, d0, target.step, dN, flip ? "FLIPS TOKEN" : ""))
            MLX.Memory.clearCache()
        }
    }

    /// Does token-exactness survive a change that is NOT a backend swap?
    ///
    /// Two within-arm controls, both between configurations the repo already
    /// treats as interchangeable:
    ///
    ///  1. `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` — contiguous prompt attention
    ///     with a different query-block width. `CBv2AttentionV1` documents
    ///     this as "NOT bit-identical to the single-call path ... results can
    ///     differ in the last ulp" and ships it as an operator latency knob.
    ///     Run this test twice with different values and diff the printed ids:
    ///     if they move, token-exactness is failing CONTIGUOUS-vs-CONTIGUOUS.
    ///  2. paged fp16 pages vs paged fp32 pages — same backend, same ring,
    ///     same gather, only the kernel's compute precision differs.
    @Test("within-backend brittleness controls")
    func withinBackendControls() async throws {
        guard Self.enabled else { return }
        let live = try await load(
            modelID: Self.gemmaID, isVLM: true, budget: 72 * Self.gib,
            prompts: [
                "List three prime numbers.",
                "Summarize the tradeoffs between contiguous and paged key-value cache "
                    + "layouts for transformer inference on unified-memory hardware, "
                    + "covering memory waste, admission, and kernel dispatch overhead.",
                "Explain, in two sentences, why the sky appears blue on a clear day.",
            ])
        let kinds = live.kinds
        let block = ProcessInfo.processInfo.environment["DARKBLOOM_CBV2_ATTN_QUERY_BLOCK"]
            ?? "(default 128)"
        print("[ctl] queryBlockSize env = \(block)")
        let contiguous = makeContiguous()
        let pagedFP16 = try makePaged(kinds: kinds)
        let pagedFP32 = try makePaged(kinds: kinds, dtype: .float32)
        for (name, prompt) in live.prompts {
            let base = try trajectory(
                label: "contiguous", model: live.serving, kinds: kinds, prompt: prompt,
                steps: 4, paged: pagedFP16, contiguous: contiguous, usePaged: { _ in false })
            print("[ctl] block=\(block) prompt='\(name)' L=\(prompt.count) contiguous ids=\(base.ids)")
            MLX.Memory.clearCache()

            let fp16 = try trajectory(
                label: "paged fp16", model: live.serving, kinds: kinds, prompt: prompt,
                steps: 4, paged: pagedFP16, contiguous: contiguous, usePaged: { _ in true })
            MLX.Memory.clearCache()
            let fp32 = try trajectory(
                label: "paged fp32", model: live.serving, kinds: kinds, prompt: prompt,
                steps: 4, paged: pagedFP32, contiguous: contiguous, usePaged: { _ in true })
            compare(fp16, fp32, tag: "CTL same backend, fp16 vs fp32 pages")
            MLX.Memory.clearCache()
        }
    }

    @Test("gpt-oss control: same probe on the backend pair that PASSES")
    func gptossControl() async throws {
        guard Self.enabled else { return }
        let live = try await load(
            modelID: Self.gptossID, isVLM: false, budget: 48 * Self.gib,
            prompts: [
                "List three prime numbers.",
                "Summarize the tradeoffs between contiguous and paged key-value cache "
                    + "layouts for transformer inference on unified-memory hardware, "
                    + "covering memory waste, admission, and kernel dispatch overhead.",
            ])
        let kinds = live.kinds
        print("[probe] gpt-oss layers=\(kinds.count) headDim=\(kinds[0].headDim)")
        let contiguous = makeContiguous()
        for (name, prompt) in live.prompts {
            print("[probe] ################ gptoss prompt '\(name)' tokens=\(prompt.count)")
            let base = try trajectory(
                label: "contiguous", model: live.serving, kinds: kinds, prompt: prompt,
                steps: 4, paged: try makePaged(kinds: kinds), contiguous: contiguous,
                usePaged: { _ in false })
            MLX.Memory.clearCache()
            let cand = try trajectory(
                label: "paged fp16", model: live.serving, kinds: kinds, prompt: prompt,
                steps: 4, paged: try makePaged(kinds: kinds), contiguous: contiguous,
                usePaged: { _ in true })
            compare(base, cand, tag: "CONTROL gptoss paged vs contiguous")
            MLX.Memory.clearCache()
        }
    }
}

// MARK: - Teacher-forced agreement

/// The measurement behind the proposed replacement gate.
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
        let probe = PagedDivergenceProbeTests()
        for (modelID, isVLM, budget) in [
            ("mlx-community/gemma-4-26B-A4B-it-qat-4bit", true, 72),
            ("mlx-community/gpt-oss-20b-MXFP4-Q8", false, 48),
        ] {
            let live = try await probe.loadForAgreement(
                modelID: modelID, isVLM: isVLM, budget: budget * 1024 * 1024 * 1024,
                prompts: Self.prompts)
            let kinds = live.kinds
            let steps = 16
            let contiguous = probe.makeContiguousBackend()
            let pagedFP16 = try probe.makePagedBackend(kinds: kinds, dtype: .float16)
            let pagedFP32 = try probe.makePagedBackend(kinds: kinds, dtype: .float32)

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
                let base = try probe.trajectoryForAgreement(
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
                        try probe.trajectoryForAgreement(
                            label: "c2", model: live.serving, kinds: kinds, prompt: prompt,
                            steps: steps, paged: pagedFP16, contiguous: contiguous, forced: f,
                            usePaged: { _ in false })
                    }),
                    ("paged-fp32(control)", { (f: [Int]) in
                        try probe.trajectoryForAgreement(
                            label: "p32", model: live.serving, kinds: kinds, prompt: prompt,
                            steps: steps, paged: pagedFP32, contiguous: contiguous, forced: f,
                            usePaged: { _ in true })
                    }),
                    ("paged-fp16(candidate)", { (f: [Int]) in
                        try probe.trajectoryForAgreement(
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
            MLX.Memory.clearCache()
        }
    }
}
