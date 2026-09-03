// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2 fail-loud factory (v0.7.5 one engine — no selection, no fallback)")
struct EngineV2FailLoudFactoryTests {

    @Test("retired selection env vars are detected for the startup WARN, never consulted")
    func retiredEnvDetection() {
        #expect(EngineV2Config.retiredEnvironmentKeysSet(environment: [:]).isEmpty)
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: ["DARKBLOOM_ENGINE_V2": "0"])
                == ["DARKBLOOM_ENGINE_V2"])
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: [
                    "DARKBLOOM_ENGINE_V2": "1",
                    "DARKBLOOM_ENGINE_V2_MODELS": "qwen3*",
                ])
                == ["DARKBLOOM_ENGINE_V2", "DARKBLOOM_ENGINE_V2_MODELS"])
        // Empty values do not count as "set".
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: ["DARKBLOOM_ENGINE_V2": ""]).isEmpty)
        // The v0.7.5 SSD offload tier RE-ADOPTED the legacy disk-budget and
        // ephemeral-KEK envs — they are live knobs again and must never be
        // WARN'd as retired (regression: the one-engine integration listed
        // them before the SSD tier merged).
        #expect(
            EngineV2Config.retiredEnvironmentKeysSet(
                environment: [
                    "DARKBLOOM_PREFIX_CACHE_DISK_GB": "20",
                    "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
                ]).isEmpty)
    }

    @Test("refusal reasons classify construction errors")
    func refusalReasonClassification() {
        struct SomeError: Error {}
        #expect(EngineV2RefusalReason.classify(
            EngineV2ProductionError.noKVHeadroom) == .noKVHeadroom)
        #expect(EngineV2RefusalReason.classify(
            EngineV2ProductionError.unsupportedModel("Qwen3Model")) == .unsupportedModel)
        #expect(EngineV2RefusalReason.classify(SomeError()) == .engineInitFailed)
    }

    @Test("factory: healthy builder → v2 bridge + one INFO kv-backend event")
    func factoryBuilds() async throws {
        let telemetry = TelemetrySink()
        let bridge = try EngineV2Factory.makeBridge(
            modelId: "gemma-4-26b-qat-4bit",
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            emitTelemetry: telemetry.callback(),
            makeEngine: {
                EngineV2Factory.ProductionBuild(
                    engine: ScriptedCBv2Engine(script: .manual),
                    fixedRequestBytes: 0,
                    kvBackendKind: .contiguous,
                    kvBackendFallbackReason: nil)
            }
        )
        #expect(await bridge.modelId == "gemma-4-26b-qat-4bit")
        #expect(await bridge.kvBackendKind == .contiguous)
        // Exactly one event is offered to the injected sink, attributing the
        // slot's serving KV backend.
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.severity == .info)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_kv_backend")
        #expect(events.first?.fields?["reason"]?.description == "contiguous")
        #expect(events.first?.fields?["model"]?.description == "gemma-4-26b-qat-4bit")
    }

    @Test("factory bridge reserves exact resolved recurrent and MTP fixed bytes")
    func factoryUsesResolvedFixedRequestBytes() async throws {
        let bytesPerGeneration = 64_389_120
        let resolvedModes = [
            ("compact-k4", 4 * bytesPerGeneration),
            ("captured-k4", 6 * bytesPerGeneration),
        ]
        for (mode, fixedRequestBytes) in resolvedModes {
            let bridge = try EngineV2Factory.makeBridge(
                modelId: "qwen3.6-\(mode)",
                tokenizer: TokenizerHandle(StubTokenizer()),
                eosTokenIds: [2],
                kvBytesPerToken: 100,
                makeEngine: {
                    EngineV2Factory.ProductionBuild(
                        engine: ScriptedCBv2Engine(script: .manual),
                        fixedRequestBytes: fixedRequestBytes,
                        kvBackendKind: .contiguous,
                        kvBackendFallbackReason: nil)
                })
            #expect(await bridge.fixedRequestBytes == fixedRequestBytes)
            #expect(
                await bridge.requestReservationBytes(tokenCount: 2)
                    == fixedRequestBytes + 200,
                "shared-budget reservation drifted for \(mode)")
            await bridge.shutdown()
        }
    }

    @Test("factory: paged fallback rides the kv-backend event reason")
    func factoryFallbackTelemetry() throws {
        let telemetry = TelemetrySink()
        _ = try EngineV2Factory.makeBridge(
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(StubTokenizer()),
            eosTokenIds: [2],
            emitTelemetry: telemetry.callback(),
            makeEngine: {
                EngineV2Factory.ProductionBuild(
                    engine: ScriptedCBv2Engine(script: .manual),
                    fixedRequestBytes: 0,
                    kvBackendKind: .contiguous,
                    kvBackendFallbackReason: "ineligible: layer 0 headDim 80")
            }
        )
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(
            events.first?.fields?["reason"]?.description
                == "fallback:ineligible: layer 0 headDim 80")
    }

    @Test("factory: init failure THROWS + ERROR engine_v2_refusal telemetry (no fallback)")
    func factoryInitFailureRefusesLoudly() {
        struct InitFailure: Error {}
        let telemetry = TelemetrySink()
        #expect(throws: InitFailure.self) {
            _ = try EngineV2Factory.makeBridge(
                modelId: "gpt-oss-20b",
                tokenizer: TokenizerHandle(StubTokenizer()),
                eosTokenIds: [2],
                emitTelemetry: telemetry.callback(),
                makeEngine: { throw InitFailure() }
            )
        }
        let events = telemetry.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .engineHealth)
        // ERROR, not WARN: with no legacy engine left a refusal must alarm.
        #expect(events.first?.severity == .error)
        #expect(events.first?.fields?["operation"]?.description == "engine_v2_refusal")
        #expect(events.first?.fields?["backend"]?.description == "engine_v2")
        #expect(events.first?.fields?["model"]?.description == "gpt-oss-20b")
        #expect(events.first?.fields?["reason"]?.description == "engine_init_failed")
        #expect(events.first?.fields?["error_class"]?.description.contains("InitFailure") == true)
        #expect(events.first?.fields?["error"]?.description.contains("InitFailure") == true)
    }

    @Test("factory: refusal reasons ride the telemetry for every classified failure")
    func factoryRefusalReasonsOnTelemetry() {
        let cases: [(any Error, String)] = [
            (EngineV2ProductionError.noKVHeadroom, "no_kv_headroom"),
            (EngineV2ProductionError.unsupportedModel("StubModel"), "unsupported_model"),
        ]
        for (error, expectedReason) in cases {
            let telemetry = TelemetrySink()
            #expect(throws: (any Error).self) {
                _ = try EngineV2Factory.makeBridge(
                    modelId: "gemma-4-26b-qat-4bit",
                    tokenizer: TokenizerHandle(StubTokenizer()),
                    eosTokenIds: [2],
                    emitTelemetry: telemetry.callback(),
                    makeEngine: { throw error }
                )
            }
            #expect(
                telemetry.events.first?.fields?["reason"]?.description == expectedReason,
                "reason for \(error)")
        }
    }



    @Test("backend config: engine_v2 still parses (retired, surfaced); concurrency keys decode")
    func backendConfigKeys() throws {
        let decoder = JSONDecoder()
        // The retired key must still DECODE so old provider.toml files load
        // (startup warns off retiredKeysPresent); the field itself is gone.
        let off = try decoder.decode(
            BackendSettings.self,
            from: Data(#"{"engine_v2": false}"#.utf8)
        )
        #expect(off.retiredKeysPresent == ["engine_v2"])
        // New concurrency keys: default 4 as of v0.8.1 (the contiguous
        // batch-curve knee — see ConfigTests), per-model override map.
        let absent = try decoder.decode(BackendSettings.self, from: Data(#"{}"#.utf8))
        #expect(absent.engineV2MaxConcurrent == BackendSettings.defaultEngineV2MaxConcurrent)
        #expect(absent.engineV2MaxConcurrentByModel.isEmpty)
        let configured = try decoder.decode(
            BackendSettings.self,
            from: Data(#"""
                {"engine_v2_max_concurrent": 6,
                 "engine_v2_max_concurrent_by_model": {"gemma-4-26b-qat-4bit": 2}}
                """#.utf8)
        )
        #expect(configured.engineV2MaxConcurrent == 6)
        #expect(configured.engineV2MaxConcurrentByModel == ["gemma-4-26b-qat-4bit": 2])
    }

    @Test("TOML: engine_v2_max_concurrent + per-model map parse from provider.toml")
    func tomlConcurrencyKeys() {
        let toml = """
            [provider]
            name = "cfg-test"

            [backend]
            engine_v2_max_concurrent = 6

            [backend.engine_v2_max_concurrent_by_model]
            "gemma-4-26b-qat-4bit" = 2
            "gpt-oss-20b" = 8
            """
        let config = ConfigManager.parse(toml)
        #expect(config.backend.engineV2MaxConcurrent == 6)
        #expect(config.backend.engineV2MaxConcurrentByModel == [
            "gemma-4-26b-qat-4bit": 2, "gpt-oss-20b": 8,
        ])
        // Missing keys use the shared v0.8.1 default. A pre-v0.8.0 file
        // instead carries a serialized `= 4`, covered in ConfigTests.
        let defaults = ConfigManager.parse("[provider]\nname = \"cfg-test\"\n")
        #expect(defaults.backend.engineV2MaxConcurrent == BackendSettings.defaultEngineV2MaxConcurrent)
        #expect(defaults.backend.engineV2MaxConcurrentByModel.isEmpty)
    }

    @Test("concurrency clamp: [1, 8] product ceiling")
    func concurrencyClamp() {
        #expect(ProviderLoop.clampEngineV2Concurrency(0) == 1)
        #expect(ProviderLoop.clampEngineV2Concurrency(1) == 1)
        #expect(ProviderLoop.clampEngineV2Concurrency(4) == 4)
        #expect(ProviderLoop.clampEngineV2Concurrency(8) == 8)
        #expect(ProviderLoop.clampEngineV2Concurrency(24) == 8)
        #expect(ProviderLoop.clampEngineV2Concurrency(UInt64.max) == 8)
    }
}

// MARK: - Shutdown
