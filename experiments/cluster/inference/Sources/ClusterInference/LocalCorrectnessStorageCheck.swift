import CryptoKit
import Foundation
import MLX

/// CPU-only checks: no MLXArray construction and no selected tensor reads.
/// The root can invoke this alongside the existing adapter metadata checks.
func checkLocalCorrectnessStorage() throws {
    var accepted = 0, rejected = 0
    let source = LocalCorrectnessStorage.maximumSourceModelTensorBytes
    let rank = LocalCorrectnessStorage.maximumRankLoadedTensorBytes
    let host = LocalCorrectnessStorage.maximumHostTensorBytes
    func counts(_ sourceBytes: Int, _ ranks: [Int], _ hosts: [Int]) throws {
        try LocalCorrectnessStorage.validateByteCounts(sourceModelTensorBytes: sourceBytes,
            rankLoadedTensorBytes: ranks, rankLargestHostTensorBytes: hosts)
    }
    func reject(_ fragment: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch {
            guard String(describing: error).contains(fragment) else {
                throw ProbeError("Local correctness check failed for an unexpected reason: \(error)")
            }
            rejected += 1; return
        }
        throw ProbeError("Local correctness check accepted an invalid fixture")
    }
    try counts(source, [rank, rank], [host, host]); accepted += 1
    try counts(5_038_041_600, [3_679_087_104, 3_679_087_104], [508_559_360, 508_559_360]); accepted += 1
    try reject("budget") { try counts(source + 1, [rank, rank], [host, host]) }
    try reject("budget") { try counts(source, [rank + 1, rank], [host, host]) }
    try reject("budget") { try counts(source, [rank, rank], [host, host + 1]) }
    try reject("budget") { try counts(source, [rank], [host]) }
    try reject("budget") { try counts(0, [rank, rank], [host, host]) }
    try reject("inconsistent") { try counts(1, [1, 1], [2, 2]) }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-storage-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Logical metadata only: a tiny pinned file backs descriptors whose large
    // shapes exercise admission arithmetic. They are deliberately not read and
    // are not advertised as valid safetensors or an executable model fixture.
    let descriptorURL = directory.appendingPathComponent("descriptor.bin")
    try Data([0]).write(to: descriptorURL)
    let file = try VerifiedCheckpoint.File(url: descriptorURL, path: "descriptor.bin", expectedSize: 1)
    let plan = try QwenPartitionPlan(configuration: JSONSerialization.data(withJSONObject: [
        "model_type": "qwen3_5_text", "hidden_size": 4096, "intermediate_size": 262144,
        "num_hidden_layers": 16, "full_attention_interval": 4,
    ], options: [.sortedKeys]), kind: .ffn)
    func fixture(shardedCount: Int, replicatedCount: Int, replicatedExtraBytes: Int = 0) throws
        -> (tensors: [String: QwenCheckpointTensor], storage: PartitionStorageCommitment) {
        var tensors: [String: QwenCheckpointTensor] = [:]
        func insert(_ name: String, shape: [Int]) throws {
            let bytes = shape.reduce(4, *)
            tensors[name] = try QwenCheckpointTensor([.init(name: name,
                tensor: TensorDescriptor(file: file, shape: shape, dtype: .uint32, offset: 0, byteCount: bytes))])
        }
        for index in 0..<shardedCount {
            try insert("model.layers.\(index).mlp.gate_proj.weight", shape: [262144, 512])
        }
        for index in 0..<replicatedCount {
            let extra = index == 0 ? replicatedExtraBytes : 0
            try insert("model.replica\(index).weight", shape: [(host + extra) / 4])
        }
        let storage = try makePartitionStorage(tensors: tensors.map { name, tensor in
            PartitionStorageTensor(name: name, shape: tensor.shape, sourceDType: tensor.dtype,
                loadedDType: tensor.dtype, byteCount: tensor.byteCount, isFeedForward: name.contains(".mlp."))
        }) { try plan.selection(name: $0, shape: $1, rank: $2) }
        return (tensors, storage)
    }
    let exact = try fixture(shardedCount: 8, replicatedCount: 4)
    guard exact.storage.sourceModelTensorBytes == source,
          exact.storage.ranks.map(\.loadedTensorBytes) == [rank, rank] else {
        throw ProbeError("Local correctness exact-bound fixture does not reach the source/rank limits")
    }
    try LocalCorrectnessStorage.validate(storage: exact.storage, tensors: exact.tensors, plan: plan)
    accepted += 1
    // Independent limits: source >6 GiB while ranks remain 4 GiB, ranks
    // >4 GiB while source remains 6 GiB, and one >512 MiB replicated tensor.
    for (sharded, replicated, extra) in [(10, 3, 0), (6, 6, 0), (1, 1, 4)] {
        let invalid = try fixture(shardedCount: sharded, replicatedCount: replicated, replicatedExtraBytes: extra)
        try reject("budget") {
            try LocalCorrectnessStorage.validate(storage: invalid.storage, tensors: invalid.tensors, plan: plan)
        }
    }
    func replacingRanks(_ ranks: [RankPartitionStorage]) -> PartitionStorageCommitment {
        PartitionStorageCommitment(schemaVersion: exact.storage.schemaVersion,
            sourceTensorManifestSHA256: exact.storage.sourceTensorManifestSHA256,
            sourceModelTensorBytes: exact.storage.sourceModelTensorBytes,
            sourceFFNTensorBytes: exact.storage.sourceFFNTensorBytes,
            sourceShardedFFNTensorBytes: exact.storage.sourceShardedFFNTensorBytes,
            sourceShardedTensorBytes: exact.storage.sourceShardedTensorBytes, ranks: ranks)
    }
    var forgedRanks = exact.storage.ranks
    let first = forgedRanks[0]
    forgedRanks[0] = RankPartitionStorage(rank: first.rank, parameterLayoutSHA256: first.parameterLayoutSHA256,
        loadedTensorBytes: first.loadedTensorBytes - 4, selectedShardedTensorBytes: first.selectedShardedTensorBytes)
    try reject("descriptor bytes differ") {
        try LocalCorrectnessStorage.validate(storage: replacingRanks(forgedRanks), tensors: exact.tensors, plan: plan)
    }
    try reject("ordered") {
        try LocalCorrectnessStorage.validate(storage: replacingRanks(Array(exact.storage.ranks.reversed())),
            tensors: exact.tensors, plan: plan)
    }

    let config = Data("{\"fixture\":1}".utf8)
    let configURL = directory.appendingPathComponent("config.json")
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let aggregate = sha256(Data(SHA256.hash(data: config)))
    let manifest = CheckpointManifest(aggregate_sha256: aggregate, file_count: 1,
        total_size_bytes: config.count,
        files: [.init(path: "config.json", sha256: sha256(config), size_bytes: config.count)])
    try config.write(to: configURL)
    try JSONEncoder().encode(manifest).write(to: manifestURL)
    _ = try VerifiedCheckpoint(directory: directory, configurationData: config)
    _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
        expectedAggregateSHA256: aggregate, maximumPayloadBytes: config.count)
    accepted += 2
    // Missing payload proves these rejections happen before opening its file.
    try FileManager.default.removeItem(at: configURL)
    try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: manifestURL)
    try reject("manifest exceeds") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: aggregate, maximumPayloadBytes: config.count)
    }
    try JSONEncoder().encode(manifest).write(to: manifestURL)
    try reject("expected aggregate") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: String(repeating: "0", count: 64))
    }
    try reject("payload exceeds") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: aggregate, maximumPayloadBytes: config.count - 1)
    }
    try reject("lowercase SHA256") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config, expectedAggregateSHA256: "bad")
    }
    try reject("nonnegative") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config, maximumPayloadBytes: -1)
    }
    try Data(repeating: 0, count: config.count).write(to: configURL)
    try reject("SHA256 mismatch") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config,
            expectedAggregateSHA256: aggregate, maximumPayloadBytes: config.count)
    }
    let overflow = CheckpointManifest(aggregate_sha256: aggregate, file_count: 2, total_size_bytes: Int.max,
        files: [.init(path: "config.json", sha256: sha256(config), size_bytes: Int.max),
                .init(path: "overflow.bin", sha256: sha256(config), size_bytes: 1)])
    try JSONEncoder().encode(overflow).write(to: manifestURL)
    try reject("byte count overflow") {
        _ = try VerifiedCheckpoint(directory: directory, configurationData: config)
    }
    struct Result: Encodable {
        let kind = "local_correctness_storage_check"
        let cpuOnly = true
        let acceptedFixtures: Int
        let rejectedFixtures: Int
        let metadataOnlyDescriptors = true
        let selectedTensorReads = 0
        let boundedManifestCheckedBeforePayloadFileOpen = true
        let expectedAggregateAndPayloadLimitCheckedBeforeFileOpen = true
    }
    try emitJSON(Result(acceptedFixtures: accepted, rejectedFixtures: rejected))
}
