import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// One token through a model as a graph, with the runtime's own request state.
// Nothing is evaluated: a dtype is a property of a graph node, and the model's
// parameters may be lazy placeholders. Shared by the Bonsai suites.
enum BonsaiLazyForward {
    struct Observation: Encodable, Equatable {
        let layers: Int
        let ingress: String
        let residualOut: String?
        let logits: String
        let declaredKV: String
        let stagedKV: [String]
        let declaredConvolution: [String]
        let stagedConvolution: [String]
        let stagedSSM: [String]
        let peakBytesDuringGraph: Int
    }

    static func name(_ dtype: DType) -> String { String(describing: dtype) }

    /// All +1 signs at the pack's three widths. Signs do not enter any dtype.
    static func transforms() throws -> PrismHadamardConfiguration {
        let widths = [5120, 6144, 17408]
        return try JSONDecoder().decode(PrismHadamardConfiguration.self, from: JSONSerialization.data(withJSONObject: [
            "prism.hadamard.version": 1, "prism.hadamard.block_size": 1024,
            "prism.hadamard.transform": "normalized-sylvester-walsh-hadamard",
            "prism.hadamard.axis": "input-last-dimension", "prism.hadamard.sign_mode": "explicit",
            "prism.hadamard.weight_names": ["forward"], "prism.hadamard.inverse_weight_names": ["inverse"],
            "prism.hadamard.sign_widths": widths,
            "prism.hadamard.sign_values": [Double](repeating: 1, count: widths.reduce(0, +)),
            "prism.hadamard.gdn_v_grouped": true,
        ] as [String: Any]))
    }

    /// `residual` nil enters through the model's embedding, as a producer
    /// stage does, and reports the residual it would send. Otherwise the
    /// token enters as a residual of that dtype, as a consumer stage's does.
    static func observe(model: any LanguageModel, configuration: Data, layers: Int,
                        residual: DType?) throws -> Observation {
        let geometry = try CBv2RequestGeometry(model: model, family: .qwen35, feedForwardKind: "dense",
            layerCount: layers, vocabularySize: 248_320, configurationData: configuration, maximumTokens: 2)
        let state = try CBv2OwnedRequestState(geometry: geometry, promptCount: 1, outputCount: 1)
        Memory.peakMemory = 0
        let before = Memory.peakMemory
        let caches = state.bank.layerCaches(rowStates: [state.rows])
        let evaluation = try state.recurrent.bind()
        let input = MLXArray([Int32(0)]).reshaped([1, 1])
        var residualOut: MLXArray?
        let logits: MLXArray
        if let residual {
            let native = try #require(model as? any CBv2PositionedRecurrentEmbeddingForwardable)
            logits = native.embeddingForward(input, inputEmbedding: MLXArray.zeros([1, 1, 5120], dtype: residual),
                cache: caches.map { $0 as! any KVCache }, recurrentState: [evaluation], positionIds: nil)
        } else {
            let native = try #require(model as? any CBv2RecurrentMTPForwardable)
            let output = native.cbv2ForwardWithHidden(input, caches: caches.map { $0 as! any KVCache },
                recurrentState: [evaluation], positionIds: nil)
            residualOut = output.lastHidden; logits = output.logits
        }
        let roots = try evaluation.evaluate()
        #expect(roots.count == 2 * geometry.recurrent.layers.count)
        let kv = state.rows.compactMap { $0 }.flatMap { row -> [String] in
            let snapshot = row.snapshot()
            return [name(snapshot.keys.dtype), name(snapshot.values.dtype)]
        }
        let observation = Observation(layers: layers, ingress: residual.map { "residual " + name($0) } ?? "tokens",
            residualOut: residualOut.map { name($0.dtype) }, logits: name(logits.dtype),
            declaredKV: name(geometry.kvDType), stagedKV: Array(Set(kv)).sorted(),
            declaredConvolution: Array(Set(geometry.recurrent.layers.map { name($0.convDType) })).sorted(),
            stagedConvolution: Array(Set(stride(from: 0, to: roots.count, by: 2).map { name(roots[$0].dtype) })).sorted(),
            stagedSSM: Array(Set(stride(from: 1, to: roots.count, by: 2).map { name(roots[$0].dtype) })).sorted(),
            peakBytesDuringGraph: Memory.peakMemory - before)
        try evaluation.rollback()
        try? state.retire(failed: true)
        return observation
    }

    static func report(_ label: String, _ observation: Observation) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("BONSAI_DTYPE_PROBE \(label) " + String(decoding: try encoder.encode(observation), as: UTF8.self))
    }
}
