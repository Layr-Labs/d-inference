import CoreFoundation
import Foundation

/// Metadata-only pricing of the raw, same-directory affine-Q4 load, or of the
/// hybrid whose feed-forward modules are NVIDIA NVFP4 (U32 words, U8 FP8 scales
/// per 16 inputs and an F32 `weight_scale_2`). This is not
/// architecture qualification: the managed loader still validates its complete
/// native inventory and source identity before allocation.
public enum GLM5NextDiscoveryLoadFootprint {
    /// Matches the native loader's `GLM5NextArtifactLimits.maximumConfigBytes`;
    /// a quantized artifact's per-module metadata makes `config.json` ~10 MB.
    public static let maximumConfigurationBytes = 32 << 20
    /// Matches the native loader's `GLM5NextArtifactLimits.maximumIndexBytes`.
    public static let maximumIndexBytes = 32 << 20
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
        public let residualAllowanceBytes: UInt64
        /// GLM's wire supplement above the raw source bytes (no disk × 1.2):
        /// native copy scratch + tokenizer + residual allowance.
        public let supplementBytes: UInt64
        public let totalBytes: UInt64
    }

    /// The managed loader copies one bounded tensor or expert bank at a time
    /// into owned arrays, so the generic disk × 1.2 padding over-counts GLM by
    /// ~34 GiB and refuses it on 256 GiB Macs. The envelope is instead the exact
    /// source bytes plus explicit native scratch, tokenizer and this residual.
    /// Measured on the staged 122-shard Q4 artifact: MLX active after the
    /// target load equals the text+vision payload (177,510,375,672 B) and the
    /// MLX peak through a 512-token prefill is 180.89 GB, i.e. ≤ 3.38 GB
    /// over residency, below the native scratch alone. The residual (1/32 of
    /// source, ≥ 1 GiB) covers unmeasured host/allocator overhead and the
    /// MTP-on construction path; activation and minimum-KV reserves still apply.
    public static func residualAllowanceBytes(sourceBytes: UInt64) -> UInt64 {
        max(1 << 30, sourceBytes / 32 + (sourceBytes % 32 == 0 ? 0 : 1))
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
        guard configuration.count <= maximumConfigurationBytes, index.count <= maximumIndexBytes,
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
            let packing = nativePacking(config),
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
                    let shape = tensor["shape"] as? [Any], shape.count <= 8,
                    let offsets = tensor["data_offsets"] as? [Any], offsets.count == 2,
                    let start = integer(offsets[0]), let end = integer(offsets[1]), end > start,
                    end <= header.payloadBytes
                else { throw Refusal.metadata }
                var bytes: UInt64
                switch dtype {
                case "U32", "F32": bytes = 4
                case "BF16": bytes = 2
                case "U8" where packing.declaresNVFP4: bytes = 1
                default: throw Refusal.metadata
                }
                // NVFP4 scales are the only byte tensors and its per-tensor
                // scale the only scalar; neither appears in the affine build.
                let isGlobalScale = name.hasSuffix(".weight_scale_2")
                guard !isGlobalScale || (packing.declaresNVFP4 && dtype == "F32" && shape.count <= 1),
                    shape.isEmpty == isGlobalScale || (isGlobalScale && shape.count == 1),
                    dtype != "U8" || (shape.count == 2 && name.hasSuffix(".scales"))
                else { throw Refusal.metadata }
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
                    guard dtype != "U32", dtype != "U8", !isGlobalScale, !name.contains(".mlp.experts.")
                    else { throw Refusal.metadata }
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
                                ["weight", "scales", "biases", "weight_scale_2"].contains(String(components[8]))
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
        let native = try add(
            try add(try multiply(largestTensor, 2), largestExpertBank),
            try add(try multiply(visionBytes, 2), 257 << 20))
        let tokenizer = max(64 << 20, try multiply(nonWeightBytes, 8))
        let residual = residualAllowanceBytes(sourceBytes: source)
        let supplement = try add(try add(native, tokenizer), residual)
        let total = try add(source, supplement)
        guard total <= UInt64(Int64.max) else { throw Refusal.overflow }
        return .init(storedBytes: storedBytes, sourceBytes: source,
            nativeTransientBytes: native, tokenizerAllowanceBytes: tokenizer,
            residualAllowanceBytes: residual, supplementBytes: supplement, totalBytes: total)
    }

    private struct Packing { let declaresNVFP4: Bool }

    /// Affine Q4/group64 by default. Per-module overrides may only select
    /// NVFP4 (4 bits, group 16) for language-model feed-forward modules; the
    /// managed loader validates the exact module set against its inventory.
    private static func nativePacking(_ config: [String: Any]) -> Packing? {
        let keys = ["quantization", "quantization_config"].filter { config[$0] != nil }
        guard !keys.isEmpty else { return nil }
        var declaresNVFP4: Bool?
        for key in keys {
            guard let q = config[key] as? [String: Any],
                integer(q["bits"]) == 4, integer(q["group_size"]) == 64,
                q["mode"] as? String == "affine" else { return nil }
            var nvfp4 = false
            for (module, raw) in q where !["bits", "group_size", "mode"].contains(module) {
                guard module.hasPrefix("model.language_model.layers."), module.contains(".mlp."),
                    let override = raw as? [String: Any], override.count == 3,
                    integer(override["bits"]) == 4, integer(override["group_size"]) == 16,
                    override["mode"] as? String == "nvfp4" else { return nil }
                nvfp4 = true
            }
            guard declaresNVFP4 == nil || declaresNVFP4 == nvfp4 else { return nil }
            declaresNVFP4 = nvfp4
        }
        return declaresNVFP4.map(Packing.init)
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
