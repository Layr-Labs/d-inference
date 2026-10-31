import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// What dtype crosses a cut of the registered Bonsai pack, and what dtype its
// request state has. The pack stores F16 scales and biases and F32 norms; the
// registered Qwen models store everything the stream touches in one dtype. A
// runtime that takes the activation dtype from the embedding's scales would
// say float16 here. This suite asks the SDK's own product class instead, and
// uses nothing of this runtime's loader.
//
// Nothing is evaluated: the product class is constructed from the registered
// configuration with fewer layers, its packed modules are replaced by shells
// of the stored shapes and dtypes whose arrays are lazy zeros, and one token
// is pushed through as a graph. The transform signs are all +1 here.

@Suite("Bonsai boundary and state dtypes (product class, lazy shells, nothing evaluated)")
struct BonsaiBoundaryDTypeTests {
    /// The registered configuration with its first `layers` layers. Everything
    /// else, including the packed module records, is the artifact's own.
    private static func configuration(layers: Int) throws -> Data {
        var root = try #require(try JSONSerialization.jsonObject(with: BonsaiFixture.data("configuration")) as? [String: Any])
        var text = try #require(root["text_config"] as? [String: Any])
        let kinds = try #require(text["layer_types"] as? [String])
        text["num_hidden_layers"] = layers
        text["layer_types"] = Array(kinds.prefix(layers))
        root["text_config"] = text
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// Replaces every packed module the configuration declares and this model
    /// has with a shell of the stored layout: U32 weight at 2 bits, F16 scales
    /// and biases at group 128. Returns how many were replaced.
    private static func installShells(_ model: PrismHadamardQwen35TextModel) throws -> Int {
        let transforms = try BonsaiLazyForward.transforms()
        let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        var replacements: [(String, Module)] = []
        for record in model.prismCheckpoint.modules {
            let name = "language_model." + record.path
            guard let module = leaves[name] else { continue }
            let rows: Int, width: Int
            if record.embedding { (rows, width) = try #require(module as? Embedding).shape }
            else { (rows, width) = try #require(module as? Linear).shape }
            let weight = MLXArray.zeros([rows, width / 16], dtype: .uint32)
            let scales = MLXArray.zeros([rows, width / 128], dtype: .float16)
            let biases = MLXArray.zeros([rows, width / 128], dtype: .float16)
            let transform = try transforms.transform(forWidth: width)
            replacements.append((name, record.embedding
                ? try HadamardQuantizedEmbedding(weight: weight, scales: scales, biases: biases,
                    groupSize: 128, bits: 2, transform: transform)
                : try HadamardQuantizedLinear(weight: weight, scales: scales, biases: biases,
                    groupSize: 128, bits: 2, transform: transform)))
        }
        try model.update(modules: ModuleChildren.unflattened(replacements), verify: [.noUnusedKeys])
        return replacements.count
    }

    /// The product class with shells, entered through its packed embedding
    /// (`residual` nil) or, with its embedding replaced by a plain placeholder
    /// of that dtype, through a residual of that dtype.
    private static func observe(layers: Int, residual: DType?)
        throws -> (observation: BonsaiLazyForward.Observation, embeddingOutput: String?, shells: Int) {
        let configuration = try configuration(layers: layers)
        let model = try PrismHadamardQwen35TextModel(configurationData: configuration)
        let shells = try installShells(model)
        // The stored layout of everything that is not packed is plain F32, and
        // the constructor's defaults already are. Checked, not assumed.
        let packed = Set(model.prismCheckpoint.modules.map { "language_model." + $0.path })
        for (path, array) in model.parameters().flattened() {
            let module = path.split(separator: ".").dropLast().joined(separator: ".")
            if packed.contains(module) {
                #expect(array.dtype == (path.hasSuffix(".weight") ? .uint32 : .float16), "\(path)")
            } else {
                #expect(array.dtype == .float32, "\(path)")
            }
        }
        var embeddingOutput: String?
        if let residual {
            try model.update(modules: ModuleChildren.unflattened([
                ("language_model.model.embed_tokens", Embedding(weight: MLXArray.zeros([1, 5120], dtype: residual))),
            ]), verify: [.noUnusedKeys])
        } else {
            let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
            let embedding = try #require(leaves["language_model.model.embed_tokens"] as? Embedding)
            embeddingOutput = BonsaiLazyForward.name(embedding(MLXArray([Int32(0)]).reshaped([1, 1])).dtype)
        }
        let observation = try BonsaiLazyForward.observe(model: model, configuration: configuration,
            layers: layers, residual: residual)
        try BonsaiLazyForward.report("product-class embeddingOutput=\(embeddingOutput ?? "none") shells=\(shells)", observation)
        return (observation, embeddingOutput, shells)
    }

    @Test(arguments: [4, 24, 28, 64])
    func theResidualLeavingAProducerStageIsFloat32(layers: Int) throws {
        let (observed, embeddingOutput, shells) = try Self.observe(layers: layers, residual: nil)
        // The packed embedding's rows are F16, the scales' dtype.
        #expect(embeddingOutput == "float16")
        // The first F32 norm promotes the stream; it never comes back.
        #expect(observed.residualOut == "float32" && observed.logits == "float32")
        #expect(observed.declaredKV == "float32" && observed.stagedKV == ["float32"])
        #expect(observed.declaredConvolution == ["float32"] && observed.stagedConvolution == ["float32"])
        #expect(observed.stagedSSM == ["float32"])
        // 3 packed modules per recurrent layer, 4 per attention layer, 3 MLP
        // modules per layer, the embedding and the head.
        #expect(shells == 2 + 3 * (layers - layers / 4) + 4 * (layers / 4) + 3 * layers)
        // A graph, not a forward: one evaluated layer of this model is 70 MiB or more.
        #expect(observed.peakBytesDuringGraph < 32 << 20)
    }

    @Test(arguments: [36, 40])
    func aConsumerStageFedFloat32KeepsFloat32State(layers: Int) throws {
        let observed = try Self.observe(layers: layers, residual: .float32).observation
        #expect(observed.logits == "float32")
        #expect(observed.declaredKV == "float32" && observed.stagedKV == ["float32"])
        #expect(observed.declaredConvolution == ["float32"] && observed.stagedConvolution == ["float32"])
        #expect(observed.stagedSSM == ["float32"])
        #expect(observed.peakBytesDuringGraph < 32 << 20)
    }

    /// What the runtime would do if it took the activation dtype from the
    /// embedding's scales: the placeholder embedding would be F16, the state
    /// would be declared F16, and the layers would produce F32 anyway.
    @Test func aConsumerStageDeclaredFromTheScalesWouldDisagreeWithItsOwnState() throws {
        let observed = try Self.observe(layers: 40, residual: .float16).observation
        #expect(observed.declaredKV == "float16")
        #expect(observed.stagedKV == ["float32"])
        #expect(observed.declaredConvolution == ["float16"] && observed.stagedConvolution == ["float32"])
    }
}
