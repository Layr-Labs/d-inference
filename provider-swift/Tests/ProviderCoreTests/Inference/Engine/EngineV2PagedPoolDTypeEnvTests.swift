// Copyright © 2026 Eigen Labs.
// Production paged storage preserves the loaded target's observed native KV
// types. An explicit scalar override is a consistency assertion, not a cast.
// Tiny real prefill/decode probes run before the pool is constructed; direct
// low-level fixed-pool arithmetic remains a separate reference control.

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

/// A tiny native-FP32 GPT-OSS target with one full and one windowed layer.
/// Production's explicit layout table keeps their storage ownership separate.
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

// MARK: - Tests

@Suite("EngineV2 paged pool dtype env knob", .serialized)
struct EngineV2PagedPoolDTypeEnvTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("native float32 reaches segmented storage without an override")
    func nativeTypesSelectActualStorage() throws {
        let built = try preparedPagedPool(environment: [:])
        #expect(built.pool.layerDTypes == [.float32, .float32])
        #expect(built.pool.groupKeys.count == 2) // full and window ownership differ
        #expect(built.pool.config.segmentSizeBytes == 64 << 20)
        let state = try built.backend.makeSequenceState(
            layerKinds: built.kinds, promptLength: 2, maxLength: 16)
        #expect(built.backend.bytesWired > 0)
        for row in state {
            let snapshot = try #require(row).snapshot()
            #expect(snapshot.keys.dtype == .float32 && snapshot.values.dtype == .float32)
        }
        built.backend.release(state)
        #expect(built.backend.bytesWired == 0)
    }

    @Test("the build reports observed native dtype for unset and matching overrides")
    func resolvedDTypeIsObservableOnTheBuild() async throws {
        for environment in [[:], [EngineV2Factory.pagedPoolDTypeEnvKey: "float32"]] {
            let build = try EngineV2Factory.makeProductionBuild(
                model: try dtypeFixtureModel(), tokenizer: StubBridgeTokenizer(),
                kvBytesCapacity: dtypeTestCapacity, maxConcurrentRequests: dtypeTestConcurrency,
                kvBackend: .paged, maxContextLength: dtypeTestContext,
                environment: environment, pagedPreflightOverride: { _ in })
            #expect(build.kvBackendKind == .paged)
            #expect(build.pagedPoolDType == "float32")
            await build.engine.shutdown()
        }
    }

    @Test("the actual paged engine queue snapshot reaches heartbeat and disappears on shutdown")
    func queueCapturedPagedTelemetryReachesBridge() async throws {
        let build = try EngineV2Factory.makeProductionBuild(
            model: try dtypeFixtureModel(), tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: dtypeTestCapacity, maxConcurrentRequests: dtypeTestConcurrency,
            kvBackend: .paged, maxContextLength: dtypeTestContext,
            environment: [:], pagedPreflightOverride: { _ in })
        let native = try #require(build.engine.capacity().pagedStorage)
        #expect(native.captureSequence > 0)
        let bridge = EngineV2Bridge(engine: build.engine, modelId: "fixture",
            tokenizer: TokenizerHandle(StubBridgeTokenizer()), eosTokenIds: [],
            kvBackendKind: .paged)
        let first = await bridge.backendSlotCapacity()
        let value = try #require(first.pagedStorage)
        let after = try #require(build.engine.capacity().pagedStorage)
        // Engine startup can publish another real capture while the actor call
        // is suspended. The heartbeat must fall within the native brackets.
        #expect(value.kind == .segmented)
        #expect(value.sampleSeq >= native.captureSequence && value.sampleSeq <= after.captureSequence)
        #expect(value.grantBytes == UInt64(native.grantBytes))
        #expect(value.committedBytes == UInt64(native.committedBytes))
        #expect(value.nominalKVBytes == native.nominalKVBytes.map(UInt64.init))
        #expect(value.physicalFloorOverheadBytes == native.physicalFloorOverheadBytes.map(UInt64.init))
        #expect(value.allocationFailuresTotal == native.allocationFailures)
        #expect(value.admissionRefusalsTotal == native.admissionRefusals)
        #expect(value.grantRefusalsTotal == native.grantRefusals)
        #expect(value.grantEpochRetriesTotal == native.grantEpochRetries)
        let repeated = await bridge.backendSlotCapacity()
        let repeatedValue = try #require(repeated.pagedStorage)
        let afterRepeated = try #require(build.engine.capacity().pagedStorage)
        #expect(repeatedValue.sampleSeq >= value.sampleSeq
                && repeatedValue.sampleSeq <= afterRepeated.captureSequence)
        #expect(repeated.pagedStorage?.generation == value.generation)
        await bridge.shutdown()
        let closed = await bridge.backendSlotCapacity()
        #expect(closed.pagedStorage == nil)
    }

    @Test("`.auto` IGNORES the page dtype entirely — malformed or not (v0.8.1)")
    func autoIgnoresThePageDTypeKnob() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        // Since v0.8.1 `.auto` resolves CONTIGUOUS, so it never reaches the
        // dtype read at all — the knob is inert on a default slot, and both
        // the old `.auto` outcomes (degrade-with-reason on a typo, fp32
        // pool on a valid value) are unreachable. Driven with a MALFORMED
        // value because that is the one an operator hits by accident: on a
        // ~94-box fleet it must cost nothing, not 503 the box and not label
        // the build as having fallen back from something it never tried.
        for raw in ["fp32", "float32"] {
            let build = try EngineV2Factory.makeProductionBuild(
                model: try dtypeFixtureModel(),
                tokenizer: StubBridgeTokenizer(),
                kvBytesCapacity: dtypeTestCapacity,
                maxConcurrentRequests: dtypeTestConcurrency,
                kvBackend: .auto,
                maxContextLength: dtypeTestContext,
                environment: [
                    EngineV2Factory.pagedPoolDTypeEnvKey: raw,
                    // Hermetic: a dev box's real crash-loop guard must not
                    // preempt the resolution under test.
                    KVBackendGuardStore.pathEnvKey: "/dev/null",
                ],
                pagedPreflightOverride: { _ in })
            #expect(build.kvBackendKind == .contiguous)
            #expect(build.kvBackendFallbackReason == nil)
            // Contiguous has no pages: the fp32 the knob was aiming at must
            // not be reported as if a pool were built with it.
            #expect(build.pagedPoolDType == nil)
            await build.engine.shutdown()
        }
    }

    @Test("an EXPLICIT paged selection + a VALID value still serves that dtype")
    func explicitPagedServesValidDType() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        // The live half of the knob after the flip, and the one the parity
        // harness depends on: it runs explicit `.paged`, so a well-formed
        // float32 must still build the fp32 pool.
        let build = try EngineV2Factory.makeProductionBuild(
            model: try dtypeFixtureModel(),
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: dtypeTestCapacity,
            maxConcurrentRequests: dtypeTestConcurrency,
            kvBackend: .paged,
            maxContextLength: dtypeTestContext,
            environment: [
                EngineV2Factory.pagedPoolDTypeEnvKey: "float32",
                KVBackendGuardStore.pathEnvKey: "/dev/null",
            ],
            pagedPreflightOverride: { _ in })
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        #expect(build.pagedPoolDType == "float32")
        await build.engine.shutdown()
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

    @Test("an explicit float16 override refuses a native float32 target")
    func mismatchedOverrideRefusesBeforeServing() throws {
        do {
            _ = try preparedPagedPool(
                environment: [EngineV2Factory.pagedPoolDTypeEnvKey: "float16"])
            Issue.record("a scalar override must not narrow the actual model's KV")
        } catch let error as EngineV2ProductionError {
            guard case .pagedUnavailable(let reason) = error else {
                Issue.record("unexpected failure: \(error)")
                return
            }
            #expect(reason.contains("native_kv_probe"))
            #expect(reason.contains("override differs"))
        }
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
