import Foundation
import MLX

struct TensorDescriptor {
    let file: VerifiedCheckpoint.File
    let shape: [Int]
    let dtype: DType
    let offset: Int
    let byteCount: Int

    func read(_ selection: TensorSelection) throws
        -> (array: MLXArray, copiedBytes: Int, readAccounting: CheckpointAlignedReadAccounting?) {
        let resultShape = try selection.resultShape(shape)
        let selectedBytes = resultShape.reduce(1, *) * dtype.size
        var data = Data(count: selectedBytes)
        var accounting: CheckpointAlignedReadAccounting?
        func copy(_ destination: UnsafeMutableRawBufferPointer, _ offset: Int) throws {
            if let part = try file.read(into: destination, offset: offset) {
                if accounting == nil { accounting = .init() }
                try accounting!.merge(part)
            }
        }
        try data.withUnsafeMutableBytes { destination in
            switch selection {
            case .all: try copy(destination, offset)
            case .axis(let axis, let ranges):
                let innerBytes = shape.dropFirst(axis + 1).reduce(dtype.size, *)
                let outerCount = shape.prefix(axis).reduce(1, *)
                let sourceStride = shape[axis] * innerBytes
                var written = 0
                for outer in 0..<outerCount {
                    for range in ranges {
                        let count = range.count * innerBytes
                        let target = UnsafeMutableRawBufferPointer(
                            start: destination.baseAddress!.advanced(by: written), count: count)
                        try copy(target, offset + outer * sourceStride + range.lowerBound * innerBytes)
                        written += count
                    }
                }
                guard written == selectedBytes else { throw ProbeError("Tensor copy byte accounting failed") }
            }
        }
        // This initializer copies bytes into MLX-owned storage; neither source file nor Data is retained.
        return (MLXArray(data, resultShape, dtype: dtype), selectedBytes, accounting)
    }
}

func tensorDescriptors(checkpoint: VerifiedCheckpoint) throws -> [String: TensorDescriptor] {
    var result: [String: TensorDescriptor] = [:]
    for file in checkpoint.files.values.sorted(by: { $0.path < $1.path })
    where file.path.hasSuffix(".safetensors") {
        guard file.size >= 8 else { throw ProbeError("Truncated safetensors file") }
        let prefix = try file.data(offset: 0, count: 8)
        let length64 = prefix.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard length64 <= 16 * 1024 * 1024, length64 <= file.size - 8 else {
            throw ProbeError("Invalid or oversized safetensors header")
        }
        let length = Int(length64)
        guard let header = try JSONSerialization.jsonObject(with: file.data(offset: 8, count: length))
            as? [String: Any] else { throw ProbeError("Invalid safetensors header object") }
        var spans: [Range<Int>] = []
        for (name, value) in header where name != "__metadata__" {
            guard result[name] == nil, let tensor = value as? [String: Any],
                let shape = tensor["shape"] as? [Int], !shape.isEmpty,
                shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }),
                let dtypeName = tensor["dtype"] as? String,
                let offsets = tensor["data_offsets"] as? [Int], offsets.count == 2,
                offsets[0] >= 0, offsets[1] >= offsets[0], offsets[1] <= file.size - 8 - length
            else { throw ProbeError("Invalid/duplicate safetensors entry: \(name)") }
            let dtype: DType
            switch dtypeName {
            case "U32": dtype = .uint32
            case "F32": dtype = .float32
            case "F16": dtype = .float16
            case "BF16": dtype = .bfloat16
            default: throw ProbeError("Unsupported checkpoint tensor dtype \(dtypeName)")
            }
            var bytes = dtype.size
            for dimension in shape {
                let product = bytes.multipliedReportingOverflow(by: dimension)
                guard !product.overflow else { throw ProbeError("Tensor byte count overflow") }
                bytes = product.partialValue
            }
            guard bytes == offsets[1] - offsets[0] else { throw ProbeError("Tensor shape/byte count mismatch") }
            spans.append(offsets[0]..<offsets[1])
            result[name] = TensorDescriptor(file: file, shape: shape, dtype: dtype,
                offset: 8 + length + offsets[0], byteCount: bytes)
        }
        let ordered = spans.sorted { $0.lowerBound < $1.lowerBound }
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            guard left.upperBound <= right.lowerBound else { throw ProbeError("Overlapping safetensors entries") }
        }
    }
    guard !result.isEmpty else { throw ProbeError("Manifest has no safetensors tensors") }
    if let index = checkpoint.files["model.safetensors.index.json"] {
        guard let object = try JSONSerialization.jsonObject(with: index.data(offset: 0, count: index.size))
            as? [String: Any], let mapping = object["weight_map"] as? [String: String],
            Set(mapping.keys) == Set(result.keys),
            mapping.allSatisfy({ result[$0.key]?.file.path == $0.value })
        else { throw ProbeError("Safetensors index does not exactly match verified tensor files") }
    }
    return result
}
