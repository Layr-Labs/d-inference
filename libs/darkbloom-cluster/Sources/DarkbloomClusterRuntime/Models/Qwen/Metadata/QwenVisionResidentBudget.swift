import DarkbloomClusterProtocol
import Foundation

/// The registered Qwen3.8 27B tower's exact scalar inventory. The actual
/// SDK constructor is checked separately at LOAD. No model or GPU is made
/// here; the same per-array bound serves native LOAD and TP placement.
struct QwenVisionResidentBudget {
    static let configurationSHA256 = "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff"
    static let inventorySHA256 = "7a37785c1e12bd106d79d462b94a950cd716bf5efd65d4e2ae198dfe561d7bfb"
    let logicalBytes: Int
    let allocationBytes: Int
    let largestTensorBytes: Int

    init(configurationSHA256: String, tensors: [QwenDenseCanonicalTensor],
         allocationBound: (Int) throws -> Int) throws {
        guard configurationSHA256 == Self.configurationSHA256,
            tensors.count == 333, Set(tensors.map(\.name)).count == tensors.count,
            QwenDenseProfileIdentity.fingerprint(tensors.sorted { $0.name < $1.name }.map(\.identity)) == Self.inventorySHA256 else {
            throw ProbeError("Qwen27 vision resident inventory differs from its registered artifact")
        }
        var logical = 0, allocated = 0, largest = 0
        for tensor in tensors {
            guard tensor.name.hasPrefix("vision_tower."), tensor.sourceDType == "BF16",
                (1...5).contains(tensor.shape.count), tensor.shape.allSatisfy({ $0 > 0 }),
                tensor.byteCount == (try QwenLongPrefillCheckedBytes.product(tensor.shape + [2])) else {
                throw ProbeError("Invalid Qwen27 vision resident shape or dtype")
            }
            let bound = try allocationBound(tensor.byteCount)
            guard bound >= tensor.byteCount, bound <= ClusterWorkerLimits.capacityBytes else {
                throw ProbeError("Qwen27 vision resident allocator bound is too small")
            }
            logical = try QwenLongPrefillCheckedBytes.sum([logical, tensor.byteCount])
            allocated = try QwenLongPrefillCheckedBytes.sum([allocated, bound])
            largest = max(largest, tensor.byteCount)
        }
        guard logical == 921_460_192 else { throw ProbeError("Qwen27 vision resident bytes differ") }
        logicalBytes = logical; allocationBytes = allocated; largestTensorBytes = largest
    }
}
