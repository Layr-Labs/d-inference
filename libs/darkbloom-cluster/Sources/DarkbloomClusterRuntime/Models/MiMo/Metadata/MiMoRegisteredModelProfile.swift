import Foundation
import MLXLLM

/// One indexed tensor as its shard header describes it. Caller-supplied
/// metadata, not a trusted descriptor or load permission: the closed profile
/// validates every entry and the exact complete inventory hash.
struct MiMoCanonicalTensor: Codable, Equatable {
    let name: String
    let shape: [Int]
    let sourceDType: String
    let byteCount: Int

    static func elementBytes(_ dtype: String) throws -> Int {
        switch dtype {
        case "U32", "F32": return 4
        case "BF16": return 2
        case "U8": return 1
        default: throw MiMoProfileError("MiMo tensor has an unsupported source dtype \(dtype)")
        }
    }

    func validate() throws {
        guard (1...512).contains(name.utf8.count), name.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 95
        }), (1...4).contains(shape.count), shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }) else {
            throw MiMoProfileError("MiMo tensor has an invalid name or bounded shape")
        }
        guard byteCount > 0,
              byteCount == (try QwenLongPrefillCheckedBytes.product(shape + [Self.elementBytes(sourceDType)])) else {
            throw MiMoProfileError("MiMo tensor shape and byte count disagree: \(name)")
        }
    }

    var identity: String {
        name + "|" + sourceDType + "|" + shape.map(String.init).joined(separator: ",") + "|" + String(byteCount)
    }
}

/// Pure identity and geometry admission of the registered MiMo artifact from
/// its configuration, its manifest and its indexed tensor headers. It owns CPU
/// metadata only. A successful value does not prove payload verification,
/// device eligibility, memory, model construction, numerical parity or execution.
struct MiMoRegisteredModelProfile {
    let specification: MiMoRegisteredSpecification
    let configurationBytes: Data
    let configuration: MiMoV26Configuration
    /// The text tensors, sorted by name.
    let tensors: [MiMoCanonicalTensor]
    /// The declared policy of every packed text module, by its indexed path.
    let quantization: [String: MiMoV26Quantization.Policy]
    let fingerprint: String

    static func admit(configuration: Data, manifest: Data, expectedArtifactAggregateSHA256: String,
                      indexedTensors: [MiMoCanonicalTensor]) throws -> Self {
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              (1...4096).contains(indexedTensors.count) else {
            throw MiMoProfileError("Registered MiMo metadata exceeds its explicit bounded input scope")
        }
        let spec = try MiMoRegisteredSpecification.specification(configuration: configuration)
        guard sha256(manifest) == spec.manifestSHA256, expectedArtifactAggregateSHA256 == spec.artifactSHA256 else {
            throw MiMoProfileError("Manifest or expected artifact is not the exact registered MiMo model")
        }
        let declared = try JSONDecoder().decode(CheckpointManifest.self, from: manifest)
        guard declared.aggregate_sha256 == spec.artifactSHA256, declared.file_count == spec.manifestFileCount,
              declared.files.count == declared.file_count,
              Set(declared.files.map(\.path)).count == declared.file_count,
              declared.total_size_bytes == spec.manifestBytes,
              try QwenLongPrefillCheckedBytes.sum(declared.files.map(\.size_bytes)) == spec.manifestBytes,
              declared.files.first(where: { $0.path == "config.json" })?.sha256 == spec.configurationSHA256,
              declared.files.contains(where: { $0.path == "model.safetensors.index.json" }) else {
            throw MiMoProfileError("Pinned registered MiMo manifest semantics differ")
        }
        let parsed = try JSONDecoder().decode(MiMoV26Configuration.self, from: configuration)
        let full = parsed.hybridLayerPattern.indices.filter { parsed.hybridLayerPattern[$0] == 0 }
        let dense = parsed.moeLayerFrequency.indices.filter { parsed.moeLayerFrequency[$0] == 0 }
        guard parsed.numHiddenLayers == spec.layers, parsed.hiddenSize == spec.hidden,
              parsed.vocabularySize == spec.vocabulary, full == spec.fullAttentionLayers,
              dense == spec.denseFeedForwardLayers, parsed.slidingWindow == spec.slidingWindow,
              parsed.routedExpertCount == spec.experts, parsed.expertsPerToken == spec.expertsPerToken,
              parsed.fullAttention.keyValueHeads == spec.fullKeyValueHeads,
              parsed.slidingAttention.keyValueHeads == spec.slidingKeyValueHeads,
              parsed.fullAttention.headDim == spec.keyWidth, parsed.slidingAttention.headDim == spec.keyWidth,
              parsed.fullAttention.valueHeadDim == spec.valueWidth,
              parsed.slidingAttention.valueHeadDim == spec.valueWidth,
              parsed.fullAttention.slidingWindow == nil, parsed.slidingAttention.slidingWindow == spec.slidingWindow,
              parsed.dtype == "bfloat16", !parsed.tieWordEmbeddings, !parsed.attentionBias,
              parsed.maxPositionEmbeddings >= MiMoRegisteredSpecification.maximumContextTokens else {
            throw MiMoProfileError("Registered MiMo geometry differs from independently pinned expectations")
        }
        for tensor in indexedTensors { try tensor.validate() }
        guard Set(indexedTensors.map(\.name)).count == indexedTensors.count else {
            throw MiMoProfileError("Indexed MiMo tensor names are duplicated")
        }
        let excluded = indexedTensors.filter { tensor in
            MiMoLayerStagePlan.excludedSourcePrefixes.contains(where: tensor.name.hasPrefix)
        }
        let text = indexedTensors.filter { tensor in
            !MiMoLayerStagePlan.excludedSourcePrefixes.contains(where: tensor.name.hasPrefix)
        }.sorted { $0.name < $1.name }
        guard text.count == spec.tensorCount, excluded.count == spec.excludedTensorCount,
              sha256(Data(text.map(\.identity).joined(separator: "\n").utf8)) == spec.inventorySHA256,
              try QwenLongPrefillCheckedBytes.sum(text.map(\.byteCount)) == spec.sourceBytes,
              try QwenLongPrefillCheckedBytes.sum(excluded.map(\.byteCount)) == spec.excludedBytes,
              text.map(\.byteCount).max() == spec.largestTensorBytes else {
            throw MiMoProfileError("Registered MiMo text inventory differs in name, shape, source dtype or bytes")
        }
        // Every text tensor has exactly one owning stage at any listed cut.
        for cut in spec.supportedCuts {
            let plan = try MiMoLayerStagePlan(configuration: configuration, cut: cut)
            let mappings = try plan.parameters(sourceNames: indexedTensors.map(\.name))
            guard mappings.count == text.count, Set(mappings.map(\.sourceName)) == Set(text.map(\.name)) else {
                throw MiMoProfileError("Registered MiMo tensor names do not match the stage Plan inventory")
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: text.map { ($0.name, $0) })
        var quantization: [String: MiMoV26Quantization.Policy] = [:]
        for scales in text where scales.name.hasSuffix(".scales") {
            let module = String(scales.name.dropLast(".scales".count))
            guard let policy = parsed.quantization.policy(for: module), let weight = byName[module + ".weight"],
                  weight.sourceDType == "U32", weight.shape.count == scales.shape.count,
                  weight.shape.dropLast() == scales.shape.dropLast(),
                  let packed = weight.shape.last, let groups = scales.shape.last,
                  // Both sides are the module's input width.
                  packed * 32 == groups * policy.groupSize * policy.bits else {
                throw MiMoProfileError("Packed MiMo module has no declared policy or a different geometry: \(module)")
            }
            if policy.mode == "affine" {
                guard scales.sourceDType == "BF16", byName[module + ".biases"] == MiMoCanonicalTensor(
                    name: module + ".biases", shape: scales.shape, sourceDType: "BF16", byteCount: scales.byteCount) else {
                    throw MiMoProfileError("Affine MiMo module lacks matching bfloat16 scales and biases: \(module)")
                }
            } else {
                guard policy.mode == "mxfp4", scales.sourceDType == "U8", byName[module + ".biases"] == nil else {
                    throw MiMoProfileError("MXFP4 MiMo module requires U8 block scales and no biases: \(module)")
                }
            }
            quantization[module] = policy
        }
        // A packed weight without scales, or loose biases, would be loaded as a float tensor.
        for tensor in text where tensor.sourceDType == "U32" || tensor.name.hasSuffix(".biases") {
            let module = tensor.name.split(separator: ".").dropLast().joined(separator: ".")
            guard quantization[module] != nil else {
                throw MiMoProfileError("Packed MiMo tensor has no packed module: \(tensor.name)")
            }
        }
        let fingerprint = sha256(Data([
            "mimo-registered-metadata-profile-v1", spec.model.rawValue, spec.configurationSHA256,
            spec.manifestSHA256, spec.artifactSHA256, spec.inventorySHA256, "manifest=\(spec.manifestBytes)",
            "source=\(spec.sourceBytes)", "count=\(spec.tensorCount)", "largest=\(spec.largestTensorBytes)",
            "native=bfloat16", "executionAuthorized=false",
        ].joined(separator: "\n").utf8))
        return .init(specification: spec, configurationBytes: configuration, configuration: parsed,
            tensors: text, quantization: quantization, fingerprint: fingerprint)
    }
}
