import Foundation
import MLX
@_spi(Cluster) import MLXLLM
import MLXLMCommon
import MLXNN

private struct CheckFailure: Error { let message: String }
private enum Injected: Error { case read, check }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw CheckFailure(message: message) }
}

private final class WeakOwners {
    weak var target: Qwen35TextModel?
    weak var replica: Embedding?
}

private func tinyConfiguration(mtpLayers: Int) throws -> Data {
    let text: [String: Any] = ["model_type": "qwen3_5_text", "hidden_size": 64,
        "num_hidden_layers": 4, "intermediate_size": 128, "num_attention_heads": 1,
        "num_key_value_heads": 1, "linear_num_value_heads": 1, "linear_num_key_heads": 1,
        "linear_key_head_dim": 32, "linear_value_head_dim": 32, "linear_conv_kernel_dim": 4,
        "vocab_size": 128, "head_dim": 64, "full_attention_interval": 4,
        "num_experts": 0, "num_experts_per_tok": 0, "mtp_num_hidden_layers": mtpLayers,
        "tie_word_embeddings": false, "max_position_embeddings": 32768]
    return try JSONSerialization.data(withJSONObject: ["model_type": "qwen3_5",
        "mtplx_mtp": ["included": true, "prefix": "mtp.", "block_size": 3],
        "mtplx_mtp_quantization": ["group_size": 64, "bits": 4, "mode": "affine"],
        "text_config": text], options: [.sortedKeys])
}

private func target() throws -> Qwen35TextModel {
    let root = try JSONSerialization.jsonObject(with: tinyConfiguration(mtpLayers: 0)) as! [String: Any]
    return Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self,
        from: JSONSerialization.data(withJSONObject: root["text_config"]!)))
}

private func tensor(shape: [Int], dtype: DType, check: () throws -> Void) throws -> MLXArray {
    // Tiny fabricated literal allocations only. No target/head forward, tokens,
    // KV cache, checkpoint payload or GPU stream is evaluated in this fixture.
    let bytes = shape.reduce(dtype.size, *)
    let value = MLXArray(Data(repeating: 0, count: bytes), shape, dtype: dtype)
    eval(value); Stream.cpu.synchronize(); try check()
    return value
}

private func replica(check: () throws -> Void) throws -> Embedding {
    let value = QuantizedEmbedding(embeddingCount: 128, dimensions: 64, groupSize: 64, bits: 4, mode: .affine)
    for (name, shape, dtype) in [("weight", [128, 8], DType.uint32),
        ("scales", [128, 1], DType.bfloat16), ("biases", [128, 1], DType.bfloat16)] {
        try value.update(parameters: ModuleParameters.unflattened([
            name: tensor(shape: shape, dtype: dtype, check: check)]), verify: [.noUnusedKeys, .shapeMismatch])
    }
    return value
}

private func identities(_ value: Module) -> [String: ObjectIdentifier] {
    Dictionary(uniqueKeysWithValues: value.leafModules().flattened().map { ($0.0, ObjectIdentifier($0.1)) })
}

@main struct MTPFactoryCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure(message: "Expected metadata fixture") }
        let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let descriptors = try JSONSerialization.jsonObject(with: raw) as! [[String: Any]]
        let names = Set(descriptors.compactMap { row -> String? in
            guard let name = row["name"] as? String, name.hasPrefix("mtp.") else { return nil }
            return String(name.dropFirst(4))
        })
        try require(names.count == 31, "Complete head names")
        try require(!_qwen35MTPEnabled, "Fixture requires unchanged global MTP attachment disabled")
        try Device.withDefaultDevice(.cpu) {
            try Stream.withNewDefaultStream(device: .cpu) {
                try MLX.withError { native in
                    func check() throws { try native.check() }
                    let configuration = try tinyConfiguration(mtpLayers: 1)
                    var groups = 0
                    let owners = WeakOwners()
                    var assistant: Qwen35InlineMTPAssistant? = try autoreleasepool {
                        let t = try target(), embedding = try replica(check: check)
                        owners.target = t; owners.replica = embedding
                        let before = identities(t)
                        var reads: [String] = []
                        let result = try Qwen35InlineMTPAssistant.loadVerifiedInline(configuration: configuration,
                            target: t, inputEmbedding: embedding, parameterNames: names, verificationMode: .serialTarget,
                            read: { name, shape, dtype in
                                reads.append(name)
                                return try tensor(shape: shape, dtype: dtype == .uint32 ? .uint32 : .bfloat16, check: check)
                            }, check: check)
                        try require(reads == names.sorted(), "One ordered callback per head parameter")
                        try require(identities(t) == before && !t.hasMTPHead, "No target module replacement or attachment")
                        try require(result.targetIdentity == t.cbv2MTPTargetIdentity, "Bound to the original target identity")
                        return result
                    }
                    try require(assistant != nil && owners.target != nil && owners.replica != nil,
                        "Assistant retains target and explicit replica")
                    assistant = nil
                    try require(owners.target == nil && owners.replica == nil, "Disposal retires both ownership roots")
                    groups += 1

                    for changedNames in [Set(names.dropFirst()), names.union(["unexpected.weight"])] {
                        let t = try target(), e = try replica(check: check)
                        var reads = 0
                        do {
                            _ = try Qwen35InlineMTPAssistant.loadVerifiedInline(configuration: configuration,
                                target: t, inputEmbedding: e, parameterNames: changedNames, verificationMode: .serialTarget,
                                read: { _, _, _ in reads += 1; throw Injected.read }, check: check)
                            throw CheckFailure(message: "Accepted incomplete head")
                        } catch is Qwen35InlineMTPError { }
                        try require(reads == 0, "Coverage refusal precedes all reads")
                    }
                    groups += 1

                    for failureAt in [0, 4, 30] {
                        let failedOwners = WeakOwners()
                        try autoreleasepool {
                            let t = try target(), e = try replica(check: check)
                            failedOwners.target = t; failedOwners.replica = e
                            let before = identities(t)
                            var reads = 0
                            do {
                                _ = try Qwen35InlineMTPAssistant.loadVerifiedInline(configuration: configuration,
                                    target: t, inputEmbedding: e, parameterNames: names, verificationMode: .serialTarget,
                                    read: { _, shape, dtype in
                                        let index = reads; reads += 1
                                        if index == failureAt { throw Injected.read }
                                        return try tensor(shape: shape, dtype: dtype == .uint32 ? .uint32 : .bfloat16, check: check)
                                    }, check: check)
                                throw CheckFailure(message: "Ignored selected read failure")
                            } catch Injected.read { }
                            try require(reads == failureAt + 1 && identities(t) == before, "Failure stops reads without altering target")
                        }
                        try require(failedOwners.target == nil && failedOwners.replica == nil,
                            "Failed factory retains no target or replica")
                    }
                    groups += 1

                    do {
                        let t = try target(), e = try replica(check: check)
                        var reads = 0
                        do {
                            _ = try Qwen35InlineMTPAssistant.loadVerifiedInline(configuration: configuration,
                                target: t, inputEmbedding: e, parameterNames: names, verificationMode: .serialTarget,
                                read: { _, _, _ in reads += 1; return MLXArray([Float(0)]) }, check: check)
                            throw CheckFailure(message: "Accepted wrong-shaped callback result")
                        } catch is Qwen35InlineMTPError { }
                        try require(reads == 1, "Malformed read result stops immediately")
                    }
                    groups += 1

                    do {
                        let t = try target(), e = try replica(check: check)
                        var reads = 0
                        do {
                            _ = try Qwen35InlineMTPAssistant.loadVerifiedInline(configuration: configuration,
                                target: t, inputEmbedding: e, parameterNames: names, verificationMode: .serialTarget,
                                read: { _, shape, dtype in
                                    reads += 1
                                    return try tensor(shape: shape, dtype: dtype, check: check)
                                }, check: { try check(); if reads == 2 { throw Injected.check } })
                            throw CheckFailure(message: "Ignored post-update callback failure")
                        } catch Injected.check { }
                        try require(reads == 2, "Post-update failure prevents next read")
                    }
                    groups += 1
                    try check()
                    print("PASS \(groups) native CPU factory/ownership groups; no model forward or generation")
                }
            }
        }
    }
}
