import Foundation
import MLX

func checkPartitionStorage() throws {
    let tensors = [
        PartitionStorageTensor(name: "replicated.weight", shape: [4, 64], sourceDType: .float32,
            loadedDType: .float32, byteCount: 1024, isFeedForward: false),
        PartitionStorageTensor(name: "ffn.weight", shape: [8, 704], sourceDType: .float16,
            loadedDType: .bfloat16, byteCount: 11264, isFeedForward: true),
    ]
    func choose(_ name: String, _ shape: [Int], _ rank: Int) throws -> TensorSelection {
        name == "ffn.weight" ? .axis(1, [rank == 0 ? 0..<320 : 320..<704]) : .all
    }
    let result = try makePartitionStorage(tensors: tensors, selection: choose)
    guard result.sourceModelTensorBytes == 12288, result.sourceShardedTensorBytes == 11264,
        result.sourceFFNTensorBytes == 11264, result.sourceShardedFFNTensorBytes == 11264,
        result.ranks.map(\.rank) == [0, 1], result.ranks.map(\.loadedTensorBytes) == [6144, 7168],
        result.ranks.map(\.selectedShardedTensorBytes) == [5120, 6144] else {
        throw ProbeError("Unequal storage commitment counters differ from the independent fixture")
    }
    for rank in 0..<2 {
        let width = rank == 0 ? 320 : 384
        let expected = "ffn.weight:bfloat16:[8, \(width)]\nreplicated.weight:float32:[4, 64]"
        guard result.ranks[rank].parameterLayoutSHA256 == sha256(Data(expected.utf8)) else {
            throw ProbeError("Storage commitment failed to bind converted dtype and rank-local layout")
        }
    }
    let reordered = try makePartitionStorage(tensors: Array(tensors.reversed()), selection: choose)
    guard try result.fingerprint == reordered.fingerprint else { throw ProbeError("Storage commitment depends on metadata input order") }
    var rejected = 0
    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { rejected += 1; return }
        throw ProbeError("Invalid partition storage was accepted")
    }
    try reject { _ = try makePartitionStorage(tensors: []) { _, _, _ in .all } }
    try reject { _ = try makePartitionStorage(tensors: tensors + [tensors[0]], selection: choose) }
    try reject { _ = try makePartitionStorage(tensors: tensors) { _, _, _ in .all } }
    // These ranges have the correct summed length, but overlap and omit64 columns.
    try reject { _ = try makePartitionStorage(tensors: tensors) { name, _, rank in
        name == "ffn.weight" ? .axis(1, [rank == 0 ? 0..<320 : 256..<640]) : .all
    } }
    try reject { _ = try makePartitionStorage(tensors: tensors) { name, _, rank in
        name == "ffn.weight" && rank == 0 ? .axis(1, [0..<320]) : .all
    } }
    try reject { _ = try makePartitionStorage(tensors: tensors) { name, _, rank in
        name == "ffn.weight" ? .axis(rank == 0 ? 0 : 1, [0..<2]) : .all
    } }
    try reject { _ = try makePartitionStorage(tensors: [PartitionStorageTensor(name: "bad", shape: [8, 704],
        sourceDType: .float16, loadedDType: .float32, byteCount: 11264, isFeedForward: true)]) { _, _, rank in
            .axis(1, [rank == 0 ? 0..<320 : 320..<704])
        }
    }
    try reject { _ = try makePartitionStorage(tensors: [PartitionStorageTensor(name: "bad", shape: [8, 704],
        sourceDType: .float16, loadedDType: .float16, byteCount: 1, isFeedForward: true)]) { _, _, rank in
            .axis(1, [rank == 0 ? 0..<320 : 320..<704])
        }
    }
    struct Result: Encodable {
        let kind = "partition_storage_commitment_check"
        let cpuOnly = true
        let disjointCoverageValidated = true
        let equalByteOverlapRejected = true
        let loadedDTypeBound = true
        let unequalRankBytes = [6144, 7168]
        let rejectedFixtures: Int
        let commitment: PartitionStorageCommitment
    }
    try emitJSON(Result(rejectedFixtures: rejected, commitment: result))
}
