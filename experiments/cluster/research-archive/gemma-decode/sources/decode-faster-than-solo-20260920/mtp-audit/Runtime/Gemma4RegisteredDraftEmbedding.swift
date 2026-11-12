import Foundation
import MLX
import MLXLMCommon
@_spi(DarkbloomCluster) import MLXLLM

/// Decode the VLM text configuration with the SAME defaults and root quantizer
/// overlays used by MLXVLM.Gemma4Configuration, without constructing a model.
private struct Gemma4DraftTargetConfiguration: Decodable {
    let text: Gemma4TextConfiguration
    enum CodingKeys: String, CodingKey { case text = "text_config", quantization, quantizationConfig = "quantization_config" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = try BaseConfiguration(from: decoder)
        let declared = try c.decodeIfPresent(BaseConfiguration.Quantization.self, forKey: .quantization)
            ?? c.decodeIfPresent(BaseConfiguration.Quantization.self, forKey: .quantizationConfig)
        var value = try Gemma4TextConfiguration(from: c.superDecoder(forKey: .text), defaults: .visionLanguageModel)
        value.mergeQuantization(base.perLayerQuantization?.quantization ?? declared)
        value.mergeQuantization(base.perLayerQuantization)
        text = value
    }
}

struct Gemma4DraftEmbeddingLoadReceipt: Encodable {
    let artifactSHA256: String, configurationSHA256: String, embeddingIdentitySHA256: String
    let selectedNames: [String]
    let selectedTensorCount: Int, loadedTensorBytes: Int, largestHostTensorBytes: Int
    let readAccounting: CheckpointAlignedReadAccounting
    let resourceAdmissionEstablished = false
}

/// Planning exposes every source tensor BEFORE native allocation. The existing
/// owner supplies the additional packed weights, read/copy staging and lookup
/// temporary allowances; neither this object nor its receipt grants admission.
struct Gemma4PreparedDraftEmbedding {
    let source: Gemma4RegisteredSource
    let selected: [Gemma4SelectedTensor]
    let targetConfiguration: Gemma4TextConfiguration
    let identitySHA256: String
    static let prefix = "language_model.model.embed_tokens"

    init(source: Gemma4RegisteredSource) throws {
        let configuration = try JSONDecoder().decode(Gemma4DraftTargetConfiguration.self,
            from: source.artifact.originalConfiguration).text
        let quantization = configuration.perLayerQuantization?.quantization(layer: Self.prefix)
        guard source.checkpoint.aggregate == Gemma4ArtifactMetadata.artifactAggregateSHA256,
              source.checkpoint.configurationSHA256 == Gemma4ArtifactMetadata.configurationSHA256,
              configuration.hiddenSize == 2816, configuration.vocabSize == 262144,
              configuration.quantizationBits == 4, configuration.quantizationGroupSize == 64,
              configuration.quantizationMode == .affine,
              quantization?.bits == 4, quantization?.groupSize == 64, quantization?.mode == .affine else {
            throw ProbeError("Registered Gemma target embedding configuration differs")
        }
        let expected: [(String, [Int], String, Int)] = [
            (Self.prefix + ".biases", [262144,44], "BF16", 23_068_672),
            (Self.prefix + ".scales", [262144,44], "BF16", 23_068_672),
            (Self.prefix + ".weight", [262144,352], "U32", 369_098_752),
        ]
        var selected: [Gemma4SelectedTensor] = []
        for (name, shape, dtype, bytes) in expected {
            let matches = source.artifact.sources.filter { $0.layout.canonicalName == name }
            guard matches.count == 1, let tensor = matches.first,
                  tensor.layout.shape == shape, tensor.layout.sourceDType == dtype,
                  tensor.layout.byteCount == bytes, source.tensors[name] != nil else {
                throw ProbeError("Registered Gemma target embedding tensor differs")
            }
            selected.append(try .init(source: tensor, localName: name))
        }
        self.source = source; self.selected = selected; self.targetConfiguration = configuration
        identitySHA256 = sha256(Data((["gemma4-target-scaled-embedding-v1", source.checkpoint.aggregate,
            source.checkpoint.configurationSHA256, "affine:4:64", "scale=sqrt(Float(hiddenSize))"]
            + selected.map { "\($0.localName):\($0.loadedDType):\($0.source.layout.shape):\($0.source.layout.byteCount)" })
            .joined(separator: "\n").utf8))
    }
}

/// Only the three verified packed arrays. No random dense Embedding initializer,
/// re-quantization, full target decoder or target KV owner is constructed.
final class Gemma4RegisteredDraftEmbedding {
    let receipt: Gemma4DraftEmbeddingLoadReceipt
    private let configuration: Gemma4TextConfiguration
    private let weight: MLXArray, scales: MLXArray, biases: MLXArray
    fileprivate init(configuration: Gemma4TextConfiguration, weight: MLXArray,
                     scales: MLXArray, biases: MLXArray, receipt: Gemma4DraftEmbeddingLoadReceipt) {
        self.configuration = configuration; self.weight = weight; self.scales = scales
        self.biases = biases; self.receipt = receipt
    }
    func conditioning() -> Gemma4MTPConditioning {
        Gemma4MTPConditioning(targetConfiguration: configuration,
            scaledEmbedding: { [self] tokens in lookup(tokens) })
    }
    /// The caller supplies validated Int32 token IDs. Kept visible to the
    /// actual-target parity check; no eager eval/readback is hidden here.
    func lookup(_ tokens: MLXArray) -> MLXArray {
        // Exact MLXNN.QuantizedEmbedding lookup followed by the original
        // Gemma4TextModel.embedTokensForDrafter scale; no new arithmetic.
        let shape = tokens.shape, indices = tokens.flattened()
        return dequantized(weight[indices], scales: scales[indices], biases: biases[indices],
            groupSize: 64, bits: 4, mode: .affine).reshaped(shape + [-1])
            * Float(configuration.hiddenSize).squareRoot()
    }
}

func materializeRegisteredGemma4DraftEmbedding(_ prepared: Gemma4PreparedDraftEmbedding,
    beforeTensor: (Gemma4SelectedTensor) throws -> Void,
    afterTensor: (Gemma4SelectedTensor) throws -> Void,
    check: () throws -> Void
) throws -> Gemma4RegisteredDraftEmbedding {
    try withoutActuallyEscaping(check) { borrowedCheck in
        try MLX.withError { native in
            func checked() throws { try native.check(); try borrowedCheck(); try native.check() }
            do {
                try checked()
                let source = prepared.source
                try source.checkpoint.checkUnchanged(); try source.checkpoint.bypassTensorPayloadCache()
                var loaded: [String: MLXArray] = [:]
                var accounting = CheckpointAlignedReadAccounting()
                var loadedBytes = 0, largestHostBytes = 0
                for selected in prepared.selected {
                    try autoreleasepool {
                        try checked(); try beforeTensor(selected); try checked()
                        guard let tensor = source.tensors[selected.localName] else {
                            throw ProbeError("Registered Gemma target embedding source disappeared")
                        }
                        let read = try tensor.read(.all), array = read.array
                        try checked()
                        guard array.shape == selected.source.layout.shape,
                              String(describing: array.dtype) == selected.sourceDType else {
                            throw ProbeError("Registered Gemma target embedding read differs")
                        }
                        eval(array); Stream.gpu.synchronize(); try checked()
                        guard array.nbytes == selected.source.layout.byteCount, read.copiedBytes == array.nbytes,
                              String(describing: array.dtype) == selected.loadedDType,
                              let storage = try array.evaluatedBufferInfo(), storage.isUnique,
                              storage.isRowContiguous, storage.dataOffset == 0,
                              storage.dataElements == array.size, storage.allocatedBytes >= array.nbytes,
                              storage.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)),
                              let part = read.readAccounting, part.selectedBytes == read.copiedBytes else {
                            throw ProbeError("Registered Gemma target embedding lacks exact owned storage/read accounting")
                        }
                        loaded[selected.localName] = array
                        loadedBytes = try LayerAttentionStateLayout.sum(loadedBytes, read.copiedBytes)
                        largestHostBytes = max(largestHostBytes, read.copiedBytes)
                        try accounting.merge(part); try checked()
                    }
                    // Only after host scratch and conversion/read scope ends.
                    try checked(); try afterTensor(selected); try checked()
                }
                guard loaded.count == 3, loadedBytes == 415_236_096,
                      accounting.selectedBytes == loadedBytes,
                      let weight = loaded[Gemma4PreparedDraftEmbedding.prefix + ".weight"],
                      let scales = loaded[Gemma4PreparedDraftEmbedding.prefix + ".scales"],
                      let biases = loaded[Gemma4PreparedDraftEmbedding.prefix + ".biases"] else {
                    throw ProbeError("Registered Gemma target embedding loaded coverage differs")
                }
                try source.checkpoint.checkUnchanged(); try checked()
                let receipt = Gemma4DraftEmbeddingLoadReceipt(artifactSHA256: source.checkpoint.aggregate,
                    configurationSHA256: source.checkpoint.configurationSHA256,
                    embeddingIdentitySHA256: prepared.identitySHA256, selectedNames: prepared.selected.map(\.localName),
                    selectedTensorCount: 3, loadedTensorBytes: loadedBytes,
                    largestHostTensorBytes: largestHostBytes, readAccounting: accounting)
                return .init(configuration: prepared.targetConfiguration, weight: weight, scales: scales,
                    biases: biases, receipt: receipt)
            } catch { try native.check(); throw error }
        }
    }
}
