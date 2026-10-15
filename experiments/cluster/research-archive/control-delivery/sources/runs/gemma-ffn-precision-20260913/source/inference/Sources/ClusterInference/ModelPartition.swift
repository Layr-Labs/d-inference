import Foundation
import MLX
import MLXNN

enum InferenceModelFamily: String, Codable { case qwen35, gemma4 }

/// Model adapters own legal tensor cuts and reduction sites; storage, workers
/// and collectives consume one shared contract.
enum ModelPartitionPlan {
    case qwen(QwenPartitionPlan)
    case gemma(GemmaPartitionPlan)

    var kind: QwenPartitionKind {
        switch self { case .qwen(let plan): plan.kind; case .gemma(let plan): plan.kind }
    }
    var fingerprint: String {
        switch self { case .qwen(let plan): plan.fingerprint; case .gemma(let plan): plan.fingerprint }
    }
    func constructionConfiguration(rank: Int) throws -> Data {
        switch self {
        case .qwen(let plan): return plan.constructionConfiguration
        case .gemma(let plan): return try plan.constructionConfiguration(rank: rank)
        }
    }
    func selection(name: String, shape: [Int], rank: Int) throws -> TensorSelection {
        switch self {
        case .qwen(let plan): return try plan.selection(name: name, shape: shape, rank: rank)
        case .gemma(let plan): return try plan.selection(name: name, shape: shape, rank: rank)
        }
    }
    func isFeedForwardTensor(_ name: String) -> Bool {
        switch self {
        case .qwen: return name.contains(".mlp.")
        case .gemma(let plan): return plan.isFeedForwardTensor(name: name)
        }
    }
}

func attachPartitionReductions(model: Module, plan: ModelPartitionPlan, collective: Collective) throws {
    switch plan {
    case .qwen(let qwen): try attachPartitionReductions(model: model, plan: qwen, collective: collective)
    case .gemma(let gemma): try attachGemmaExecution(model: model, plan: gemma, collective: collective)
    }
}

func modelParameterLayout(_ model: Module) -> String {
    let entries = model.parameters().flattened().map { path, value in "\(path):\(value.dtype):\(value.shape)" }
    return sha256(Data(entries.sorted().joined(separator: "\n").utf8))
}

func syntheticPartitionStorage(_ source: Module, plan: ModelPartitionPlan) throws -> PartitionStorageCommitment {
    let tensors = source.parameters().flattened().map { name, value in
        PartitionStorageTensor(name: name, shape: value.shape, sourceDType: value.dtype,
            loadedDType: value.dtype, byteCount: value.nbytes, isFeedForward: plan.isFeedForwardTensor(name))
    }
    return try makePartitionStorage(tensors: tensors) { try plan.selection(name: $0, shape: $1, rank: $2) }
}
