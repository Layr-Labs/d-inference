import Foundation
import MLX
@_spi(Benchmarking) import MLXLMCommon

struct ReplayTensorDescriptor: Codable {
    let file, dtype, byteOrder, sha256: String
    let shape, packedStrides: [Int]
    let byteCount: Int

    var nativeDType: DType {
        get throws {
            switch dtype {
            case "float16": return .float16
            case "bfloat16": return .bfloat16
            case "float32": return .float32
            default: throw ReplayFailure.invalidInput("unsupported native dtype")
            }
        }
    }

    func validate(name: String) throws {
        try require(file == name + ".bin" && byteOrder == "little", "flat native payload required")
        try require(shape.count == 4 && shape.allSatisfy({ (1...32768).contains($0) }), "bounded rank-four shape required")
        var count = 1, strides = [Int](repeating: 0, count: 4)
        for i in (0..<4).reversed() {
            strides[i] = count
            let (next, overflow) = count.multipliedReportingOverflow(by: shape[i])
            try require(!overflow && next <= 32 << 20, "tensor product exceeds bound")
            count = next
        }
        let bytes = try count * nativeDType.size
        try require(bytes <= 32 << 20 && bytes == byteCount && strides == packedStrides,
                    "native byte count or strides mismatch")
        try require(sha256.count == 64 && sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                    "invalid tensor hash")
    }
}

struct ReplayGeometry: Codable, Equatable {
    let queryHeads, kvHeads, length, headDim, inputBytes: Int
    let pageSize, poolBudgetBytes, segmentTargetBytes, allocationBoundBytes: Int

    init(_ value: CBv2AttentionReplay.Geometry) {
        queryHeads = value.queryHeads; kvHeads = value.kvHeads; length = value.length
        headDim = value.headDim; inputBytes = value.inputBytes; pageSize = value.pageSize
        poolBudgetBytes = value.poolBudgetBytes; segmentTargetBytes = value.segmentTargetBytes
        allocationBoundBytes = value.allocationBoundBytes
    }
}

struct ReplaySelection: Decodable {
    let requestID: UInt64
    let outputIndex, storageLayerIndex, modelLayerIndex, offsetBefore, offsetAfter: Int
    let phase, dispatch: String
}

struct ReplayTransfer: Decodable {
    let schema, packetSHA256, metadataSHA256, sampleOutcome: String
    let identity: [String: String]
    let selection: ReplaySelection
    let scaleBits: UInt32
    let geometry: ReplayGeometry
    let tensors: [String: ReplayTensorDescriptor]

    static func load(_ options: ReplayOptions) throws -> (ReplayTransfer, CBv2AttentionReplay.Input) {
        let raw = try readBounded(options.input, limit: 256 << 10)
        try require(sha256(raw) == options.inputSHA256, "validated transfer hash mismatch")
        let transfer = try JSONDecoder().decode(Self.self, from: raw)
        try require(transfer.schema == "darkbloom.attention-replay-input.v1"
            && transfer.sampleOutcome == "confirmed", "validated confirmed transfer required")
        for hash in [transfer.packetSHA256, transfer.metadataSHA256,
                     transfer.identity["artifactSHA256"] ?? "", transfer.identity["inputSHA256"] ?? ""] {
            try require(hash.count == 64 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                        "invalid source identity hash")
        }
        let selection = transfer.selection
        try require(selection.requestID > 0 && (1...1_000_000).contains(selection.outputIndex)
            && selection.storageLayerIndex >= 0 && selection.modelLayerIndex >= 0
            && selection.offsetBefore >= 0 && selection.offsetBefore < 32768
            && selection.offsetAfter == selection.offsetBefore + 1
            && ["decode", "chained_decode"].contains(selection.phase), "invalid selected identity")
        let dispatches = ["contiguous": ["contiguous_sdpa"],
                         "paged": ["paged_fixed_decode", "paged_segmented_decode"]]
        try require(dispatches[transfer.identity["backend"] ?? ""]?.contains(selection.dispatch) == true,
                    "original dispatch identity mismatch")
        let names = Set(["queries", "storedKeys", "storedValues", "incomingKeys", "incomingValues", "output"])
        try require(Set(transfer.tensors.keys) == names, "six exact native payloads required")
        var total = 0
        for (name, tensor) in transfer.tensors {
            try tensor.validate(name: name); total += tensor.byteCount
        }
        try require(total <= 32 << 20, "native transfer exceeds 32 MiB")
        var tensors = [String: CBv2AttentionReplay.Tensor]()
        let root = options.input.deletingLastPathComponent()
        for (name, descriptor) in transfer.tensors {
            let data = try readBounded(root.appendingPathComponent(descriptor.file), limit: 32 << 20)
            try require(data.count == descriptor.byteCount && sha256(data) == descriptor.sha256,
                        "native payload length/hash mismatch")
            tensors[name] = try .init(bytes: data, shape: descriptor.shape, dtype: descriptor.nativeDType)
        }
        let input = CBv2AttentionReplay.Input(queries: tensors["queries"]!, storedKeys: tensors["storedKeys"]!,
            storedValues: tensors["storedValues"]!, incomingKeys: tensors["incomingKeys"]!,
            incomingValues: tensors["incomingValues"]!, scaleBits: transfer.scaleBits)
        try require(tensors["output"]!.shape == input.queries.shape
            && tensors["output"]!.dtype == input.queries.dtype, "original outward output geometry mismatch")
        let observed = try CBv2AttentionReplay.validate(input)
        try require(ReplayGeometry(observed) == transfer.geometry && observed.length == selection.offsetAfter,
                    "declared allocation/visible geometry mismatch")
        return (transfer, input)
    }
}
