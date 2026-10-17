import Foundation
import MLX

/// Physical stored-tensor ranges. Model adapters resolve logical and quantized axes.
enum TensorSelection: Equatable {
    case all
    case axis(Int, [Range<Int>])

    func resultShape(_ shape: [Int]) throws -> [Int] {
        guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else {
            throw ProbeError("Tensor selection requires a nonempty positive shape")
        }
        guard case .axis(let axis, let ranges) = self else { return shape }
        guard shape.indices.contains(axis), !ranges.isEmpty else {
            throw ProbeError("Invalid selected tensor axis or empty ranges")
        }
        var previous = 0, count = 0
        for range in ranges {
            guard range.lowerBound >= previous, range.upperBound <= shape[axis], !range.isEmpty else {
                throw ProbeError("Tensor ranges must be ordered, disjoint and within the source axis")
            }
            previous = range.upperBound
            count += range.count
        }
        var output = shape
        output[axis] = count
        return output
    }

    var signature: String {
        switch self {
        case .all: return "all"
        case .axis(let axis, let ranges):
            return "axis=\(axis);" + ranges.map { "\($0.lowerBound):\($0.upperBound)" }.joined(separator: ",")
        }
    }
}

/// Used for bounded synthetic fixtures and the independent in-memory slice oracle.
/// MLX `copy` shares storage, and `take` on an interior axis can leave a
/// transposed gather result. Gather even `.all`, then force row-major layout.
/// Releasing the intermediate before inspecting uniqueness distinguishes owned
/// materialization from a compact-looking alias of the source.
func copySelectedTensor(_ source: MLXArray, selection: TensorSelection) throws -> MLXArray {
    let expected = try selection.resultShape(source.shape)
    let array = autoreleasepool {
        let axis: Int
        let indices: MLXArray
        switch selection {
        case .all:
            axis = 0
            indices = MLXArray(Array(0..<source.dim(0)))
        case .axis(let selectedAxis, let ranges):
            axis = selectedAxis
            indices = MLXArray(ranges.flatMap { Array($0) })
        }
        let gathered = source.take(indices, axis: axis)
        let contiguous = gathered.contiguous(allowColMajor: false, stream: .gpu)
        eval(contiguous)
        return contiguous
    }
    // eval waits for the output event, which may precede Metal completion-handler
    // cleanup. That handler retains input Data (including Synchronizer inputs),
    // so isUnique can remain false after the values are already readable. This
    // load-time synchronization completes those GPU references before inspecting
    // ownership; it does not clear the cache or loosen allocation bounds.
    Stream.gpu.synchronize()
    guard array.shape == expected else { throw ProbeError("Selected tensor has the wrong shape") }
    let bound = try Memory.allocationFootprintUpperBound(byteCount: array.nbytes)
    guard let buffer = try array.evaluatedBufferInfo() else {
        throw ProbeError("Selected tensor has no evaluated storage: \(selection.signature)")
    }
    guard buffer.dataOffset == 0, buffer.isUnique, buffer.isRowContiguous,
        buffer.dataElements == array.size, buffer.allocatedBytes >= array.nbytes,
        buffer.allocatedBytes <= bound else {
        throw ProbeError("Selected tensor is not independently materialized: \(selection.signature), "
            + "shape=\(array.shape), dtype=\(array.dtype), bytes=\(array.nbytes), bound=\(bound), "
            + "allocated=\(buffer.allocatedBytes), offset=\(buffer.dataOffset), "
            + "elements=\(buffer.dataElements)/\(array.size), rowContiguous=\(buffer.isRowContiguous), unique=\(buffer.isUnique)")
    }
    return array
}
