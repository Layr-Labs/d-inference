import CoreFoundation
import Foundation

/// Metadata-only pricing of the raw, same-directory affine-Q4 load. This is not
/// architecture qualification: the managed loader still validates its complete
/// native inventory and source identity before allocation.
public enum GLM5NextDiscoveryLoadFootprint {
    public struct Header {
        public let tensors: [String: Any]
        public let fileBytes: UInt64
        public let payloadBytes: UInt64

        public init(tensors: [String: Any], fileBytes: UInt64, payloadBytes: UInt64) {
            self.tensors = tensors
            self.fileBytes = fileBytes
            self.payloadBytes = payloadBytes
        }
    }

    public struct Estimate: Equatable, Sendable {
        public let storedBytes: UInt64
        public let sourceBytes: UInt64
        public let nativeTransientBytes: UInt64
        public let tokenizerAllowanceBytes: UInt64
        /// GLM's wire supplement is added AFTER the generic disk × 1.2 basis.
        public let supplementBytes: UInt64
        public let totalBytes: UInt64
    }

    private enum Refusal: Error { case metadata, overflow }
    private static let maximumMetadataBytes: UInt64 = 256 << 20

    /// `files` is the complete, flat integrity-file inventory with stat sizes.
    /// The Core adapter supplies its existing bounded safetensors reader. No
    /// tensor payload, hash, device query, or native array is needed here.
    public static func estimate(
        configuration: Data, index: Data, files: [String: UInt64],
        readHeader: (String) -> Header?
    ) -> Estimate? {
        try? inspect(configuration: configuration, index: index, files: files, readHeader: readHeader)
    }

    private static func inspect(
        configuration: Data, index: Data, files: [String: UInt64],
        readHeader: (String) -> Header?
    ) throws -> Estimate {
        guard configuration.count <= 2 << 20, index.count <= 32 << 20,
            files.count <= 4096,
            let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
            config["model_type"] as? String == "glm5_next",
            let text = config["text_config"] as? [String: Any],
            text["model_type"] as? String == "glm5_next_text",
            let layers = integer(text["num_hidden_layers"]), (1...512).contains(layers),
            integer(text["num_nextn_predict_layers"]) == 1,
            let experts = integer(text["n_routed_experts"]), (1...2048).contains(experts),
            let vision = config["vision_config"] as? [String: Any],
            vision["model_type"] as? String == "glm5_next_vision",
            nativeQ4(config),
            let rawIndex = try JSONSerialization.jsonObject(with: index) as? [String: Any],
            let weightMap = rawIndex["weight_map"] as? [String: String],
            !weightMap.isEmpty, weightMap.count <= 200_000,
            let metadata = rawIndex["metadata"] as? [String: Any],
            let indexedBytes = integer(metadata["total_size"]), indexedBytes > 0
        else { throw Refusal.metadata }

        let required: Set<String> = [
            "config.json", "model.safetensors.index.json", "tokenizer.json",
            "tokenizer_config.json", "chat_template.jinja", "processor_config.json",
        ]
        guard required.isSubset(of: Set(files.keys)),
            files["config.json"] == UInt64(configuration.count),
            files["model.safetensors.index.json"] == UInt64(index.count)
        else { throw Refusal.metadata }
        var stored: UInt64 = 0, nonWeight: UInt64 = 0
        for (name, bytes) in files {
            guard safeName(name), ModelScanner.isIntegrityFile(name), bytes > 0 else {
                throw Refusal.metadata
            }
            if ModelScanner.isWeightFile(name) {
                guard name.hasSuffix(".safetensors") else { throw Refusal.metadata }
                stored = try add(stored, bytes)
            } else {
                guard bytes <= (name == "tokenizer.json" ? 512 << 20 : 32 << 20) else {
                    throw Refusal.metadata
                }
                nonWeight = try add(nonWeight, bytes)
            }
        }
        let shards = Set(weightMap.values)
        guard !shards.isEmpty, shards.count <= 256,
            shards == Set(files.keys.filter { $0.hasSuffix(".safetensors") }),
            shards.allSatisfy(safeName)
        else { throw Refusal.metadata }

        var seen = Set<String>()
        var banks: [String: UInt64] = [:]
        var largest: UInt64 = 0, totalPayload: UInt64 = 0, visionBytes: UInt64 = 0
        var textBytes: UInt64 = 0, mtpBytes: UInt64 = 0, packedMatrices = 0
        var metadataBytes = try add(UInt64(configuration.count), UInt64(index.count))
        for shard in shards.sorted() {
            guard let header = readHeader(shard), header.fileBytes == files[shard],
                header.fileBytes > header.payloadBytes,
                header.fileBytes - header.payloadBytes > 8,
                header.fileBytes - header.payloadBytes <= (16 << 20) + 8
            else { throw Refusal.metadata }
            metadataBytes = try add(metadataBytes, header.fileBytes - header.payloadBytes)
            guard metadataBytes <= maximumMetadataBytes else { throw Refusal.metadata }
            var ranges: [(start: UInt64, end: UInt64)] = []
            for (name, raw) in header.tensors where name != "__metadata__" {
                guard name.utf8.count <= 4096, seen.insert(name).inserted,
                    weightMap[name] == shard,
                    let tensor = raw as? [String: Any],
                    let dtype = tensor["dtype"] as? String,
                    let shape = tensor["shape"] as? [Any], !shape.isEmpty, shape.count <= 8,
                    let offsets = tensor["data_offsets"] as? [Any], offsets.count == 2,
                    let start = integer(offsets[0]), let end = integer(offsets[1]), end > start,
                    end <= header.payloadBytes
                else { throw Refusal.metadata }
                var bytes: UInt64
                switch dtype {
                case "U32", "F32": bytes = 4
                case "BF16": bytes = 2
                default: throw Refusal.metadata
                }
                for rawDimension in shape {
                    guard let dimension = integer(rawDimension), dimension > 0 else {
                        throw Refusal.metadata
                    }
                    bytes = try multiply(bytes, dimension)
                }
                guard bytes == end - start else { throw Refusal.metadata }
                if dtype == "U32" {
                    guard shape.count == 2, name.hasSuffix(".weight") else { throw Refusal.metadata }
                    packedMatrices += 1
                }
                ranges.append((start, end))
                largest = max(largest, bytes)
                totalPayload = try add(totalPayload, bytes)
                metadataBytes = try add(metadataBytes, UInt64(1024 + name.utf8.count * 4))
                guard metadataBytes <= maximumMetadataBytes else { throw Refusal.metadata }

                if name.hasPrefix("model.visual."), name.count > "model.visual.".count {
                    guard dtype != "U32", !name.contains(".mlp.experts.") else { throw Refusal.metadata }
                    visionBytes = try add(visionBytes, bytes)
                } else {
                    let components = name.split(separator: ".", omittingEmptySubsequences: false)
                    if components.count >= 5, components.allSatisfy({ !$0.isEmpty }),
                        components[0] == "model", components[1] == "language_model", components[2] == "layers",
                        let layer = UInt64(components[3]), String(layer) == String(components[3]), layer <= layers {
                        if components.contains("experts") {
                            guard components.count == 9, components[4] == "mlp", components[5] == "experts",
                                let expert = UInt64(components[6]), String(expert) == String(components[6]), expert < experts,
                                ["gate_proj", "up_proj", "down_proj"].contains(String(components[7])),
                                ["weight", "scales", "biases"].contains(String(components[8]))
                            else { throw Refusal.metadata }
                            // Same destination as nativeName: remove ONLY the expert ID.
                            let bank = components.enumerated().filter { $0.offset != 6 }
                                .map { String($0.element) }.joined(separator: ".")
                            banks[bank] = try add(banks[bank, default: 0], bytes)
                        }
                        if layer == layers { mtpBytes = try add(mtpBytes, bytes) }
                        else { textBytes = try add(textBytes, bytes) }
                    } else if ["lm_head.weight", "lm_head.scales", "lm_head.biases",
                        "model.language_model.embed_tokens.weight", "model.language_model.embed_tokens.scales",
                        "model.language_model.embed_tokens.biases", "model.language_model.norm.weight"].contains(name) {
                        textBytes = try add(textBytes, bytes)
                    } else { throw Refusal.metadata }
                }
            }
            var cursor: UInt64 = 0
            for range in ranges.sorted(by: { $0.start < $1.start }) {
                guard range.start == cursor else { throw Refusal.metadata }
                cursor = range.end
            }
            guard cursor == header.payloadBytes else { throw Refusal.metadata }
        }
        guard seen == Set(weightMap.keys), totalPayload == indexedBytes,
            textBytes > 0, mtpBytes > 0, visionBytes > 0, packedMatrices > 0, !banks.isEmpty
        else { throw Refusal.metadata }
        return try quotation(
            storedBytes: stored, nonWeightBytes: nonWeight, largestTensor: largest,
            largestExpertBank: banks.values.max() ?? 0, visionBytes: visionBytes)
    }

    /// Pure arithmetic, kept internal so only metadata-checked estimates escape.
    static func quotation(
        storedBytes: UInt64, nonWeightBytes: UInt64, largestTensor: UInt64,
        largestExpertBank: UInt64, visionBytes: UInt64
    ) throws -> Estimate {
        guard storedBytes > 0, largestTensor > 0, largestTensor <= storedBytes,
            largestExpertBank > 0, largestExpertBank <= storedBytes,
            visionBytes > 0, visionBytes <= storedBytes else { throw Refusal.metadata }
        let source = try add(storedBytes, nonWeightBytes)
        let generic = try add(source, try add(source / 5, source % 5 == 0 ? 0 : 1))
        let native = try add(
            try add(try multiply(largestTensor, 2), largestExpertBank),
            try add(try multiply(visionBytes, 2), 257 << 20))
        let tokenizer = max(64 << 20, try multiply(nonWeightBytes, 8))
        let supplement = try add(native, tokenizer)
        let total = try add(generic, supplement)
        guard total <= UInt64(Int64.max) else { throw Refusal.overflow }
        return .init(storedBytes: storedBytes, sourceBytes: source,
            nativeTransientBytes: native, tokenizerAllowanceBytes: tokenizer,
            supplementBytes: supplement, totalBytes: total)
    }

    private static func nativeQ4(_ config: [String: Any]) -> Bool {
        let keys = ["quantization", "quantization_config"].filter { config[$0] != nil }
        guard !keys.isEmpty else { return false }
        return keys.allSatisfy { key in
            guard let q = config[key] as? [String: Any],
                Set(q.keys).isSubset(of: ["bits", "group_size", "mode"]),
                integer(q["bits"]) == 4, integer(q["group_size"]) == 64,
                q["mode"] as? String == "affine" else { return false }
            return true
        }
    }

    private static func integer(_ raw: Any?) -> UInt64? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.utf8.contains(0)
    }

    private static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw Refusal.overflow }
        return result.partialValue
    }

    private static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw Refusal.overflow }
        return result.partialValue
    }
}
