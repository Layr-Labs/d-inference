import Foundation
import MLX

/// Canonical runtime tensor backed by one stored tensor, or by a gate/up pair.
/// Fusion happens AFTER selecting local rows; no full expert bank is assembled.
struct QwenCheckpointTensor {
    struct Part { let name: String; let tensor: TensorDescriptor }
    let parts: [Part]
    let shape: [Int]
    let dtype: DType
    let byteCount: Int

    init(_ parts: [Part]) throws {
        guard let first = parts.first, parts.count == 1 || parts.count == 2 else {
            throw ProbeError("Invalid checkpoint tensor composition")
        }
        var shape = first.tensor.shape
        if parts.count == 2 {
            guard shape.count == 3, parts[1].tensor.shape == shape,
                parts[1].tensor.dtype == first.tensor.dtype,
                shape[1] <= Int.max / 2 else {
                throw ProbeError("Split expert gate/up tensors must have matching rank-three shapes and dtypes")
            }
            shape[1] *= 2
        }
        let bytes = first.tensor.byteCount.multipliedReportingOverflow(by: parts.count)
        guard !bytes.overflow else { throw ProbeError("Composed tensor byte count overflow") }
        self.parts = parts; self.shape = shape; self.dtype = first.tensor.dtype; self.byteCount = bytes.partialValue
    }

    var sourceModulePaths: [String] {
        parts.map { $0.name.split(separator: ".").dropLast().joined(separator: ".") }
    }

    func read(_ selection: TensorSelection) throws
        -> (array: MLXArray, copiedBytes: Int, largestHostTensorBytes: Int) {
        let expected = try selection.resultShape(shape)
        if parts.count == 1 {
            let read = try parts[0].tensor.read(selection)
            return (read.array, read.copiedBytes, read.copiedBytes)
        }
        let ranges: [Range<Int>]
        switch selection {
        case .all: ranges = [0..<shape[1]]
        case .axis(let axis, let selected):
            guard axis == 1 else { throw ProbeError("Fused expert gate/up selection must use output rows") }
            ranges = selected
        }
        var pieces: [MLXArray] = [], copied = 0, largest = 0, offset = 0
        for part in parts {
            let end = offset + part.tensor.shape[1]
            let local = ranges.compactMap { range -> Range<Int>? in
                let lower = max(offset, range.lowerBound), upper = min(end, range.upperBound)
                return lower < upper ? (lower - offset)..<(upper - offset) : nil
            }
            if !local.isEmpty {
                let read = try part.tensor.read(.axis(1, local))
                pieces.append(read.array); copied += read.copiedBytes
                largest = max(largest, read.copiedBytes)
            }
            offset = end
        }
        guard !pieces.isEmpty else { throw ProbeError("Empty expert row selection") }
        let array = pieces.count == 1 ? pieces[0]
            : concatenated(pieces, axis: 1).contiguous(allowColMajor: false, stream: .gpu)
        eval(array); Stream.gpu.synchronize()
        guard array.shape == expected, array.dtype == dtype, array.nbytes == copied else {
            throw ProbeError("Selected expert fusion has inconsistent shape or byte count")
        }
        return (array, copied, largest)
    }
}

func composeQwenCheckpointTensors(_ tensors: [String: TensorDescriptor]) throws
    -> [String: QwenCheckpointTensor] {
    var result: [String: QwenCheckpointTensor] = [:]
    var consumed = Set<String>()
    for name in tensors.keys.sorted() {
        guard !consumed.contains(name) else { continue }
        if let marker = name.range(of: ".switch_mlp.gate_proj.") {
            let prefix = String(name[..<marker.lowerBound]) + ".switch_mlp."
            let suffix = String(name[marker.upperBound...])
            guard ["weight", "scales", "biases"].contains(suffix) else {
                throw ProbeError("Unsupported split expert suffix")
            }
            let up = prefix + "up_proj." + suffix
            let fused = prefix + "gate_up_proj." + suffix
            guard let upper = tensors[up], tensors[fused] == nil, result[fused] == nil else {
                throw ProbeError("Missing expert up half or conflicting fused/split tensors")
            }
            result[fused] = try QwenCheckpointTensor([
                .init(name: name, tensor: tensors[name]!), .init(name: up, tensor: upper)])
            consumed.insert(name); consumed.insert(up)
        } else {
            guard !name.contains(".switch_mlp.up_proj.") else {
                throw ProbeError("Expert up half has no matching gate tensor")
            }
            result[name] = try QwenCheckpointTensor([.init(name: name, tensor: tensors[name]!)])
            consumed.insert(name)
        }
    }
    return result
}
