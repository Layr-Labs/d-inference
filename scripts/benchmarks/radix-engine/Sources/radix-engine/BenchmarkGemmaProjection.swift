#if RADIX_CANDIDATE
import CryptoKit
import Foundation
import MLX
@_spi(Diagnostics) import MLXLLM
import MLXLMCommon

enum BenchmarkGemmaProjection {
    static func capture(target: any LanguageModel, tokens: [Int], verifiedModelSHA256: String,
                        directory: URL) throws -> Data {
        guard let target = target as? Gemma4TextModel,
            !FileManager.default.fileExists(atPath: directory.path) else {
            throw RadixBenchmark.Failure.message("Gemma projection requires a text target and a fresh output directory")
        }
        let snapshot = try target.diagnosticLayer0Projections(tokens: tokens)
        eval(Array(snapshot.tensors.values))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var tensors: [String: Any] = [:]
        for name in snapshot.tensors.keys.sorted() {
            let tensor = snapshot.tensors[name]!
            let packed = tensor.asData(access: .copy)
            let filename = name + ".bin"
            try packed.data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            var description = describe(tensor)
            description["file"] = filename
            description["packed_strides"] = packed.strides
            tensors[name] = description
        }
        let parameters = snapshot.parameters.mapValues(describe)
        let quantization = snapshot.quantization.mapValues {
            ["group_size": $0.groupSize, "bits": $0.bits, "mode": $0.mode] as [String: Any]
        }
        var differences: [String: Any] = [:]
        for name in ["embedding", "normalized", "q", "k", "v"] {
            differences[name] = compare(snapshot.tensors["m1." + name]!,
                snapshot.tensors["m2." + name]![0..., 0..<1, 0...])
        }
        let body: [String: Any] = [
            "schema": "darkbloom.gemma-layer0-projection.v1", "status": "captured",
            "verified_model_sha256": verifiedModelSHA256, "token_ids": tokens,
            "directory": directory.path, "layer": 0, "tensors": tensors,
            "parameter_identities": parameters, "quantization": quantization,
            "first_column_comparisons": differences,
            "kernel_observation": "not_instrumented; M1/M2 dispatch identity requires separate trace or source evidence",
            "embedding_parameter_identity": "bound by verified_model_sha256",
            "scope": "Actual embedding, inputLayernorm and Q/K/V modules; first column at widths one and two. Caller must bind the second token to the retained proposal record. No attention or later layers are evaluated.",
            "timing_scope": "Projection evaluation and native-byte export are diagnostic overhead; this process is not performance evidence.",
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("projection.json"), options: .atomic)
        return data
    }

    private static func describe(_ tensor: MLXArray) -> [String: Any] {
        let original = tensor.asData(access: .noCopy)
        let packed = tensor.asData(access: .copy)
        return ["dtype": String(describing: original.dType), "shape": original.shape,
                "strides": original.strides, "byte_count": packed.data.count,
                "sha256": SHA256.hash(data: packed.data).map { String(format: "%02x", $0) }.joined()]
    }

    static func compare(_ single: MLXArray, _ firstColumn: MLXArray) -> [String: Any] {
        precondition(single.shape == firstColumn.shape && single.dtype == firstColumn.dtype)
        let leftBytes = single.asData(access: .copy).data
        let rightBytes = firstColumn.asData(access: .copy).data
        let itemSize = single.dtype.size
        let bitwiseMismatches = stride(from: 0, to: leftBytes.count, by: itemSize).filter {
            leftBytes[$0..<($0 + itemSize)] != rightBytes[$0..<($0 + itemSize)]
        }.count
        let left = single.asArray(Float.self), right = firstColumn.asArray(Float.self)
        let errors = zip(left, right).map { abs(Double($0) - Double($1)) }
        let finite = left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite)
        return ["element_count": single.size, "bitwise_mismatch_count": bitwiseMismatches,
                "finite": finite, "identical": leftBytes == rightBytes,
                "max_absolute_error": finite ? (errors.max() ?? 0) as Any : NSNull(),
                "mean_absolute_error": finite ? (errors.reduce(0, +) / Double(errors.count)) as Any : NSNull()]
    }
}
#endif
