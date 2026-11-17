// Copyright © 2026 Eigen Labs.
//
// The native KV type probe runs a real forward on the target. A later
// construction over the same loaded target, such as the MTP assistant upgrade's
// replacement engine, runs while the current engine may still serve that target
// on its own queue, so it must reuse the first observation instead of running
// another forward. CPU only: a stateful compiled trace held open on a second
// thread stands in for the concurrent work that makes such a forward unsafe.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing

@testable import ProviderCore

private func decodeObservationConfig<T: Decodable>(_ json: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(T.self, from: data)
}

/// 2-layer Gemma-4 text: [sliding(16), full], no KV sharing, headDim 64.
private func observationGemma4Text() throws -> Gemma4TextModel {
    let config: MLXLLM.Gemma4TextConfiguration = try decodeObservationConfig([
        "model_type": "gemma4_text",
        "hidden_size": 64,
        "num_hidden_layers": 2,
        "intermediate_size": 128,
        "num_attention_heads": 4,
        "head_dim": 64,
        "global_head_dim": 64,
        "vocab_size": 128,
        "vocab_size_per_layer_input": 128,
        "num_key_value_heads": 2,
        "num_kv_shared_layers": 0,
        "hidden_size_per_layer_input": 32,
        "sliding_window": 16,
        "sliding_window_pattern": 2,
        "max_position_embeddings": 2048,
        "use_double_wide_mlp": false,
    ])
    return Gemma4TextModel(config)
}

/// Traces a stateful compiled function over a module on its own thread and holds
/// the trace open. Meanwhile mlx-swift has swapped the module's live parameters
/// for the trace's placeholders, which have no primitive, and holds the eval lock.
private final class OpenParameterTrace: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var traced: (([MLXArray]) -> [MLXArray])?

    /// Returns once the trace is open over `module`.
    func open(over module: Module) -> Bool {
        let entered = entered
        let release = release
        traced = compile(inputs: [module]) { (arguments: [MLXArray]) -> [MLXArray] in
            entered.signal()
            // Bounded: a forward elsewhere waits for this trace's eval lock.
            _ = release.wait(timeout: .now() + 1)
            return [arguments[0] + 1]
        }
        Thread { [self] in
            Device.withDefaultDevice(.cpu) { _ = traced?([MLXArray(Float(1))]) }
            finished.signal()
        }.start()
        return entered.wait(timeout: .now() + 30) == .success
    }

    func close() {
        release.signal()
        _ = finished.wait(timeout: .now() + 30)
        traced = nil
    }
}

@Suite("Native KV type observation", .serialized)
struct NativeKVTypeObservationTests {
    @Test("a later construction over the same target reuses its observation and runs no forward")
    func laterConstructionReusesObservation() throws {
        try Device.withDefaultDevice(.cpu) {
            let model = try observationGemma4Text()
            let adapter = try #require(EngineV2Factory.ProductionModelAdapter(model: model))
            // The first construction observes the target before any engine serves it.
            let first = try EngineV2Factory.probeNativeKVTypes(model: model, adapter: adapter)

            let trace = OpenParameterTrace()
            defer { trace.close() }
            try #require(trace.open(over: model), "the trace over the target never started")
            let later = try EngineV2Factory.probeNativeKVTypes(model: model, adapter: adapter)
            #expect(later == first)
        }
    }

    /// The control for the test above: a target that was never observed is
    /// probed, and that forward fails as the shared-target race does. It also
    /// fails if compilation is disabled, which would make the test above vacuous.
    @Test("an unobserved target is probed, and a forward during a trace over it fails")
    func unobservedTargetIsProbed() throws {
        try Device.withDefaultDevice(.cpu) {
            let observed = try observationGemma4Text()
            let observedAdapter = try #require(EngineV2Factory.ProductionModelAdapter(model: observed))
            _ = try EngineV2Factory.probeNativeKVTypes(model: observed, adapter: observedAdapter)

            let model = try observationGemma4Text()
            let adapter = try #require(EngineV2Factory.ProductionModelAdapter(model: model))
            let trace = OpenParameterTrace()
            defer { trace.close() }
            try #require(trace.open(over: model), "the trace over the target never started")
            let error = #expect(throws: (any Error).self) {
                try EngineV2Factory.probeNativeKVTypes(model: model, adapter: adapter)
            }
            #expect(String(describing: error).contains("without a primitive"))
        }
    }
}
