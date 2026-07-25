// Copyright © 2026 Eigen Labs.
//
// `DARKBLOOM_CBV2_PAGED_KV_DTYPE` — the paged pool's page dtype, selectable
// from the environment dictionary already threaded into
// `EngineV2Factory.makeProductionBuild`. Three properties, in the order
// they matter:
//
//   1. The knob REACHES the pool. Every assertion here reads the pool the
//      factory actually constructed (`usablePageCount`, `bytesPhysical`,
//      `reserve`) or the resolved dtype the build reports, never the
//      `PagedKVPoolConfig` literal the test handed in. A knob that is
//      merely accepted is a capability flag; a knob whose slabs changed
//      size is evidence.
//   2. A typo REFUSES. The seam exists so a parity harness can run an fp32
//      control arm; a mistyped value that silently served fp16 would give
//      it a second copy of the baseline, which looks exactly like
//      agreement. This is the one paged env knob that cannot fall back.
//   3. fp32 pages cost 2x, and the physical plan is computed at the fp16
//      rate — so the same grant buys HALF the pages, half the seats, and a
//      grant that fits at fp16 can refuse outright at fp32. That refusal
//      is the correct answer and is pinned below.
//
// These tests construct pools but never run a forward pass. Slabs default
// to `.atFirstAdmission`, so nothing here materializes GPU memory.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Fixture

private func decodeDTypeConfig<T: Decodable>(_ json: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(T.self, from: data)
}

/// 2-layer GPT-OSS, headDim 64 / 2 KV heads on BOTH layers, so the pool
/// builds exactly one slab group and its page arithmetic is a single
/// number instead of a proportional split.
private func dtypeFixtureModel() throws -> GPTOSSModel {
    let config: GPTOSSConfiguration = try decodeDTypeConfig([
        "model_type": "gpt_oss",
        "num_hidden_layers": 2,
        "num_local_experts": 4,
        "num_experts_per_tok": 2,
        "vocab_size": 128,
        "rms_norm_eps": 1e-5,
        "hidden_size": 64,
        "intermediate_size": 64,
        "head_dim": 64,
        "num_attention_heads": 4,
        "num_key_value_heads": 2,
        "sliding_window": 32,
    ])
    return GPTOSSModel(config)
}

private let dtypeTestCapacity = 8 << 20
private let dtypeTestConcurrency = 2
private let dtypeTestContext = 2048

/// Prepare a PAGED backend through the real production path and hand back
/// the pool it built. `pagedPreflightOverride` is the gate suite's idiom
/// for keeping the assertion on THIS seam rather than on Metal resource
/// packaging.
private func preparedPagedPool(
    environment: [String: String],
    capacityBytes: Int = dtypeTestCapacity
) throws -> (pool: PagedKVPool, backend: PagedKVBackend, kinds: [CBv2LayerKind]) {
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let model = try dtypeFixtureModel()
    let prepared = try EngineV2Factory.prepareProductionBackend(
        model: model,
        kvBytesCapacity: capacityBytes,
        maxConcurrentRequests: dtypeTestConcurrency,
        kvBackend: .paged,
        maxContextLength: dtypeTestContext,
        environment: environment,
        pagedPreflightOverride: { _ in })
    #expect(prepared.kind == .paged)
    let (backend, _) = try prepared.consume(
        model: model, maxConcurrentRequests: dtypeTestConcurrency)
    guard let paged = backend as? PagedKVBackend else {
        throw CBv2KVError.backendIneligible(
            reason: "prepared backend was \(type(of: backend)), not PagedKVBackend")
    }
    return (paged.pool, paged, prepared.layerKinds)
}

/// Reserve `maxLength`-token rows against `backend` until the pool refuses,
/// and return how many were seated. This is the ADMISSION consequence
/// measured rather than restated: `PagedKVPool.pageDemand` charges pages,
/// not bytes, so the per-row charge is identical at both dtypes and the
/// only thing that moved is how many pages exist to charge against.
private func seatableRows(
    backend: PagedKVBackend, kinds: [CBv2LayerKind], maxLength: Int
) -> Int {
    var seated = 0
    while seated < 4_096 {
        do {
            try backend.reserve(layerKinds: kinds, maxLength: maxLength)
            seated += 1
        } catch {
            return seated
        }
    }
    return seated
}

// MARK: - Tests

@Suite("EngineV2 paged pool dtype env knob", .serialized)
struct EngineV2PagedPoolDTypeEnvTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("float32 reaches the constructed pool's slabs, not just its config")
    func float32SelectsFP32Pages() throws {
        let fp32 = try preparedPagedPool(
            environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"])
        let fp16 = try preparedPagedPool(environment: [:])

        #expect(fp32.pool.groupKeys.count == 1)
        #expect(fp32.pool.groupKeys == fp16.pool.groupKeys)
        let key = try #require(fp32.pool.groupKeys.first)

        // THE read-back. `usablePageCount` and `bytesPhysical` are computed
        // from `PagedKVGroup.pageBytes`, which multiplies by the GROUP's
        // own dtype — the slab geometry the pool actually built, not the
        // config struct this test passed in. Same byte budget, half the
        // pages: `pageBytes` doubled underneath.
        let fp32Pages = fp32.pool.usablePageCount(group: key)
        let fp16Pages = fp16.pool.usablePageCount(group: key)
        // The whole arithmetic, pinned as numbers rather than a ratio.
        // `PagedKVPhysicalCapacityPolicy` is dtype-BLIND — it plans at
        // `fp16BytesPerToken` — so BOTH pools get the identical byte
        // budget: min(8 MiB grant, 2048 ctx * 2 rows * 1024 B/token) =
        // 4 MiB. One group, so groupBytes == 4_194_304 B, and
        // pageCount = groupBytes / pageBytes gives 4_194_304 / 8_192 = 512
        // at fp16 and 4_194_304 / 16_384 = 256 at fp32, each less the one
        // poison page.
        #expect(fp16Pages == 511)
        #expect(fp32Pages == 255)
        #expect(fp16Pages + 1 == 2 * (fp32Pages + 1))
        // Same bytes, half the pages, half the tokens. The pool did not
        // get smaller; each token got twice as expensive.
        #expect(fp32.pool.bytesPhysical == fp16.pool.bytesPhysical)
        #expect(fp32.pool.bytesPhysical == 4 << 20)
        #expect(fp32Pages * fp32.pool.config.pageSize == 4_080)
        #expect(fp16Pages * fp16.pool.config.pageSize == 8_176)
    }

    @Test("the resolved dtype is reported on the build, and reports float16 when unset")
    func resolvedDTypeIsObservableOnTheBuild() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        for (value, expected) in [("float32", "float32"), ("float16", "float16")] {
            let build = try EngineV2Factory.makeProductionBuild(
                model: try dtypeFixtureModel(),
                tokenizer: StubBridgeTokenizer(),
                kvBytesCapacity: dtypeTestCapacity,
                maxConcurrentRequests: dtypeTestConcurrency,
                kvBackend: .paged,
                maxContextLength: dtypeTestContext,
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: value],
                pagedPreflightOverride: { _ in })
            #expect(build.kvBackendKind == .paged)
            #expect(build.pagedPoolDType == expected)
            await build.engine.shutdown()
        }
        // Unset is float16 — stated, not inferred from absence.
        let unset = try EngineV2Factory.makeProductionBuild(
            model: try dtypeFixtureModel(),
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: dtypeTestCapacity,
            maxConcurrentRequests: dtypeTestConcurrency,
            kvBackend: .paged,
            maxContextLength: dtypeTestContext,
            environment: [:],
            pagedPreflightOverride: { _ in })
        #expect(unset.pagedPoolDType == "float16")
        await unset.engine.shutdown()
    }

    @Test("an unrecognized value REFUSES instead of silently serving float16")
    func unrecognizedValueRefusesLoudly() throws {
        // Every one of these is a plausible operator typo, and every one of
        // them would otherwise have produced a float16 pool wearing an
        // fp32 label.
        for raw in ["fp32", "float64", "f32", "32", "true", "bfloat16", "float 32"] {
            var thrown: Error?
            #expect(throws: EngineV2ProductionError.self) {
                do {
                    _ = try preparedPagedPool(
                        environment: [EngineV2Factory.pagedPoolDTypeEnvKey: raw])
                } catch {
                    thrown = error
                    throw error
                }
            }
            guard case .invalidPagedPoolDType(let echoed)? =
                thrown as? EngineV2ProductionError
            else {
                Issue.record("expected .invalidPagedPoolDType for \"\(raw)\", got \(thrown as Any)")
                continue
            }
            // The refusal echoes the offending value verbatim and is
            // classified apart from a paged-infrastructure failure, so a
            // typo cannot masquerade as a paged rollout regression.
            #expect(echoed == raw)
            #expect("\(thrown!)".contains(EngineV2Factory.pagedPoolDTypeEnvKey))
            #expect("\(thrown!)".contains("expected float16 or float32"))
            #expect(
                EngineV2RefusalReason.classify(thrown!) == .pagedKVDTypeInvalid)
        }
    }

    @Test("recognized values tolerate case and surrounding whitespace")
    func recognizedValuesAreNormalized() throws {
        for raw in ["Float32", "FLOAT32", " float32 ", "float32\n"] {
            let built = try preparedPagedPool(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: raw])
            #expect(built.pool.config.dtype == .float32)
        }
        // An EMPTY value is how a shell spells "unset"; it must not refuse.
        #expect(try EngineV2Factory.pagedPoolDType(
            environment: [EngineV2Factory.pagedPoolDTypeEnvKey: ""]) == .float16)
        #expect(try EngineV2Factory.pagedPoolDType(environment: [:]) == .float16)
    }

    @Test("the contiguous backend ignores the knob and reports no page dtype")
    func contiguousIgnoresTheKnob() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let build = try EngineV2Factory.makeProductionBuild(
            model: try dtypeFixtureModel(),
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: dtypeTestCapacity,
            maxConcurrentRequests: dtypeTestConcurrency,
            kvBackend: .contiguous,
            maxContextLength: dtypeTestContext,
            // Deliberately hostile: a value that WOULD refuse on paged.
            // Contiguous has no pages, so it never reads the knob.
            environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "fp32"],
            pagedPreflightOverride: { _ in })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.pagedPoolDType == nil)
        await build.engine.shutdown()
    }

    @Test("a float32 request that degrades to contiguous reports NO dtype, not float32")
    func degradedPagedReportsNoDType() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        // The fp32 arm's worst failure mode: the knob is set, the run
        // believes it measured fp32 pages, and the kill switch quietly put
        // it on contiguous. `pagedPoolDType` must follow the RESOLVED
        // backend, exactly as `kvBackendKind` does.
        let build = try EngineV2Factory.makeProductionBuild(
            model: try dtypeFixtureModel(),
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: dtypeTestCapacity,
            maxConcurrentRequests: dtypeTestConcurrency,
            kvBackend: .paged,
            maxContextLength: dtypeTestContext,
            environment: [
                EngineV2Factory.pagedPoolDTypeEnvKey: "float32",
                EngineV2KVBackendPolicy.killSwitchEnvKey: "0",
            ],
            pagedPreflightOverride: { _ in })
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == "kill_switch")
        #expect(build.pagedPoolDType == nil)
        await build.engine.shutdown()
    }

    @Test("fp32 halves the seats: the same grant admits about half as many rows")
    func fp32HalvesAdmission() throws {
        let fp16 = try preparedPagedPool(environment: [:])
        let fp32 = try preparedPagedPool(
            environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"])

        let fp16Rows = seatableRows(
            backend: fp16.backend, kinds: fp16.kinds, maxLength: 256)
        let fp32Rows = seatableRows(
            backend: fp32.backend, kinds: fp32.kinds, maxLength: 256)

        #expect(fp32Rows > 0)
        // Page DEMAND is dtype-blind, so the per-row charge is identical
        // and the seat count tracks the page count exactly: floor division
        // over half as many usable pages, hence 2x within one row of
        // rounding on each side.
        #expect(fp16Rows >= 2 * fp32Rows)
        #expect(fp16Rows <= 2 * fp32Rows + 2)
    }

    @Test("a grant that fits at float16 REFUSES at float32 rather than serving half a pool")
    func fp32RefusesAGrantThatFitsAtFP16() throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let kinds = try dtypeFixtureModel().cbv2LayerKinds
        let key = PagedKVGroupKey(kinds[0])
        // pageBytes = 2 (K+V) * kvHeads * pageSize * headDim * dtype.size
        //           = 2 * 2 * 16 * 64 * 2 = 8_192 B at fp16, 16_384 at fp32.
        let pageBytesFP16 =
            2 * key.kvHeads * CBv2PagedDefaults.pageSize * key.headDim
            * MemoryLayout<Float16>.size
        #expect(pageBytesFP16 == 8_192)
        // A group needs TWO pages before it can serve anyone: one poison,
        // one tenant. Three fp16 pages of budget is one fp32 page.
        let grant = 3 * pageBytesFP16

        func config(_ dtype: DType) -> PagedKVPoolConfig {
            PagedKVPoolConfig(
                capacityBytes: grant, dtype: dtype,
                maxPrefillChunk: 16, nominalMaxSequenceLength: 256)
        }

        let fp16 = try PagedKVBackend(layerKinds: kinds, config: config(.float16))
        #expect(fp16.pool.usablePageCount(group: key) == 2)

        do {
            _ = try PagedKVBackend(layerKinds: kinds, config: config(.float32))
            Issue.record("fp32 must refuse a grant that only holds one page")
        } catch let error as CBv2KVError {
            guard case .capacityExhausted(let needed, let available) = error else {
                Issue.record("expected capacityExhausted, got \(error)")
                return
            }
            // The arithmetic, verbatim: two fp32 pages are 32_768 B and the
            // grant is 24_576 B. Refused — never served at half the size.
            #expect(needed == 2 * 2 * pageBytesFP16)
            #expect(available == grant)
        }
    }
}
