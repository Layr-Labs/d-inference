import CryptoKit
import Foundation
import MLX
import MLXNN

struct LoaderFixture {
    let parameters: [String: MLXArray]
    let sourceTensorCount: Int
    let sourcePartsPerTensor: [String: Int]
    let aggregateSHA256: String
    let fp16MetadataTensorCount: Int
}

func writeLoaderFixture(_ loaded: LoadedModel, directory: URL, fp16FFNMetadata: Bool) throws -> LoaderFixture {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try loaded.configurationData.write(to: directory.appendingPathComponent("config.json"))
    let parameters = loaded.model.parameters().flattened().map { key, array in
        // Include attention and GDN metadata: full partition loading must exercise
        // the same F16-to-BF16 conversion as the established FFN fixture.
        let convert = fp16FFNMetadata && key.contains(".layers.")
            && (key.hasSuffix(".scales") || key.hasSuffix(".biases"))
        return (key, convert ? array.asType(.float16) : array)
    }.sorted { $0.0 < $1.0 }
    // Mirror the registered MoE checkpoint: its stored gate/up triplets are
    // separate even though the runtime model and partition plan are fused.
    var stored: [String: MLXArray] = [:], parts: [String: Int] = [:]
    for (key, array) in parameters {
        if loaded.feedForwardKind == "moe", let marker = key.range(of: ".switch_mlp.gate_up_proj.") {
            guard array.ndim == 3, array.dim(1) % 2 == 0 else { throw ProbeError("Invalid fused expert fixture") }
            let prefix = String(key[..<marker.lowerBound]) + ".switch_mlp."
            let suffix = String(key[marker.upperBound...]), width = array.dim(1) / 2
            stored[prefix + "gate_proj." + suffix] = try copySelectedTensor(array, selection: .axis(1, [0..<width]))
            stored[prefix + "up_proj." + suffix] = try copySelectedTensor(array, selection: .axis(1, [width..<(2 * width)]))
            parts[key] = 2
        } else { stored[key] = array; parts[key] = 1 }
    }
    let sourceParameters = stored.sorted { $0.key < $1.key }
    var index: [String: String] = [:]
    for shard in 0..<2 {
        let name = "weights-\(shard).safetensors"
        let selected = sourceParameters.enumerated().filter { $0.offset % 2 == shard }.map { ($0.element.key, $0.element.value) }
        try save(arrays: Dictionary(uniqueKeysWithValues: selected), url: directory.appendingPathComponent(name))
        for (key, _) in selected { index[key] = name }
    }
    let data = try JSONSerialization.data(withJSONObject: ["weight_map": index], options: [.sortedKeys])
    try data.write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    try writeFixtureManifest(directory)
    let manifest = try JSONDecoder().decode(CheckpointManifest.self,
        from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    return LoaderFixture(parameters: Dictionary(uniqueKeysWithValues: parameters),
        sourceTensorCount: stored.count, sourcePartsPerTensor: parts,
        aggregateSHA256: manifest.aggregate_sha256,
        fp16MetadataTensorCount: stored.values.filter { $0.dtype == .float16 }.count)
}

/// Source-file bytes are computed before runtime dtype conversion. In these fixtures
/// only F16-to-BF16 changes dtype, so source and resident byte widths happen to agree.
struct LoaderSourceAccounting: Encodable {
    let sourceModelTensorBytes: Int
    let sourceFFNTensorBytes: Int
    let sourceShardedFFNTensorBytes: Int
    let sourceShardedTensorBytes: Int
    let selectedSourceTensorBytes: Int
    let largestSelectedSourceTensorBytes: Int
    let tensorCount: Int
    let sourceTensorCount: Int
    let selectedTensorCount: Int

    init(_ fixture: LoaderFixture, plan: QwenPartitionPlan, rank: Int) throws {
        var total = 0, ffn = 0, shardedFFN = 0, sharded = 0, selected = 0, largest = 0, selectedCount = 0
        for (name, value) in fixture.parameters {
            let selection = try plan.selection(name: name, shape: value.shape, rank: rank)
            let selectedBytes = try selection.resultShape(value.shape).reduce(value.dtype.size, *)
            total += value.nbytes
            if name.contains(".mlp.") {
                ffn += value.nbytes
                if selection != .all { shardedFFN += value.nbytes }
            }
            if selection != .all { sharded += value.nbytes; selectedCount += 1 }
            selected += selectedBytes
            largest = max(largest, selectedBytes / fixture.sourcePartsPerTensor[name]!)
        }
        guard selected == total - sharded / 2, sharded > 0, sharded % 2 == 0 else {
            throw ProbeError("Fixture source accounting does not describe a two-rank partition")
        }
        sourceModelTensorBytes = total; sourceFFNTensorBytes = ffn; sourceShardedFFNTensorBytes = shardedFFN
        sourceShardedTensorBytes = sharded; selectedSourceTensorBytes = selected
        largestSelectedSourceTensorBytes = largest; tensorCount = fixture.parameters.count
        sourceTensorCount = fixture.sourceTensorCount
        selectedTensorCount = selectedCount
    }

    func verify(_ receipt: DirectShardLoadReceipt, fixture: LoaderFixture, rank: Int) throws {
        guard receipt.rank == rank, receipt.verifiedAggregateSHA256 == fixture.aggregateSHA256,
            receipt.sourceModelTensorBytes == sourceModelTensorBytes,
            receipt.sourceFFNTensorBytes == sourceFFNTensorBytes,
            receipt.sourceShardedFFNTensorBytes == sourceShardedFFNTensorBytes,
            receipt.sourceShardedTensorBytes == sourceShardedTensorBytes,
            receipt.loadedTensorBytes == selectedSourceTensorBytes,
            receipt.largestHostTensorBytes == largestSelectedSourceTensorBytes,
            receipt.tensorCount == tensorCount, receipt.sourceTensorCount == sourceTensorCount else {
            throw ProbeError("Direct loader receipt differs from independently counted fixture source bytes")
        }
    }
}

func writeFixtureManifest(_ directory: URL) throws {
    let names = ["config.json", "model.safetensors.index.json", "weights-0.safetensors", "weights-1.safetensors"]
    var hasher = SHA256()
    let entries = try names.sorted().map { name in
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        let digest = SHA256.hash(data: data)
        digest.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return CheckpointManifest.Entry(path: name, sha256: sha256(data), size_bytes: data.count)
    }
    let manifest = CheckpointManifest(
        aggregate_sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
        file_count: entries.count, total_size_bytes: entries.reduce(0) { $0 + $1.size_bytes }, files: entries)
    try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
}

func expectedShardParameters(_ original: LoadedModel, rank: Int,
                             plan: QwenPartitionPlan) throws -> [String: MLXArray] {
    var expected = Dictionary(uniqueKeysWithValues: original.model.parameters().flattened())
    if plan.kind == .full || plan.isMoE {
        // This oracle gathers the already loaded source tensor in memory. It does
        // not use TensorDescriptor.read or the direct reader's byte-span logic.
        for (name, value) in expected {
            expected[name] = try copySelectedTensor(value,
                selection: plan.selection(name: name, shape: value.shape, rank: rank))
        }
        return expected
    }
    for (path, module) in original.model.namedModules() where path.hasSuffix(".mlp") {
        let shard = try FFNWeights(module: module, path: path).shard(rank: rank)
        for (name, linear) in [("gate_proj", shard.gate), ("up_proj", shard.up), ("down_proj", shard.down)] {
            for (key, value) in linear.parameters().flattened() { expected[path + "." + name + "." + key] = value }
        }
    }
    return expected
}

func combineLoadedShards(into baseline: LoadedModel, shards: [LoadedModel]) throws {
    let children = shards.map { Dictionary(uniqueKeysWithValues: $0.model.namedModules()) }
    let modules = baseline.model.namedModules()
    let parents = Dictionary(uniqueKeysWithValues: modules)
    for (path, _) in modules where path.hasSuffix(".mlp") {
        if baseline.feedForwardKind == "moe" {
            let parts = try children.map { modules -> Module in
                guard let block = modules[path] else { throw ProbeError("Missing loaded MoE block") }
                return block
            }
            let parent = parents[String(path.dropLast(".mlp".count))]!
            try parent.update(modules: ModuleChildren(values: [
                "mlp": .value(try LocalSummedFeedForward(parts)),
            ]), verify: [.noUnusedKeys])
            continue
        }
        let weights = try children.map { modules in
            try FFNWeights(module: modules[path]!, path: path, requireTwoWaySplit: false)
        }
        let parent = parents[String(path.dropLast(".mlp".count))]!
        try parent.update(modules: ModuleChildren(values: [
            "mlp": .value(LocalPartitionedFFN(shards: weights)),
        ]), verify: [.noUnusedKeys])
    }
}
