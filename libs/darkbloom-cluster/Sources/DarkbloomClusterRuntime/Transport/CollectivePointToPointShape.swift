import Foundation
import MLX

/// Local admission, never inferred from an unchecked remote header. The wire
/// layer applies its tighter control/residual limits before constructing this.
struct CollectivePointToPointShape {
    static let maximumDimensions = 4
    static let hardByteLimit = 16 * 1024 * 1024
    static let allowedDTypes: Set<DType> = [.uint8, .uint32, .int32, .float16, .bfloat16, .float32]

    let shape: [Int]
    let dtype: DType
    let elements: Int
    let byteCount: Int

    init(shape: [Int], dtype: DType, maximumBytes: Int) throws {
        guard (1...Self.hardByteLimit).contains(maximumBytes),
            (1...Self.maximumDimensions).contains(shape.count),
            Self.allowedDTypes.contains(dtype) else {
            throw ProbeError("Point-to-point transfer has an unsupported shape, dtype or byte limit")
        }
        var elements = 1
        for dimension in shape {
            guard dimension > 0, dimension <= Int(Int32.max) else {
                throw ProbeError("Point-to-point dimensions must be positive C Int values")
            }
            let product = elements.multipliedReportingOverflow(by: dimension)
            guard !product.overflow else { throw ProbeError("Point-to-point element count overflow") }
            elements = product.partialValue
        }
        let bytes = elements.multipliedReportingOverflow(by: dtype.size)
        guard !bytes.overflow, bytes.partialValue > 0, bytes.partialValue <= maximumBytes else {
            throw ProbeError("Point-to-point transfer exceeds the admitted byte limit")
        }
        self.shape = shape
        self.dtype = dtype
        self.elements = elements
        self.byteCount = bytes.partialValue
    }

    func validateMetadata(_ array: MLXArray) throws {
        guard array.shape == shape, array.dtype == dtype,
            array.size == elements, array.nbytes == byteCount else {
            throw ProbeError("Point-to-point transfer changed native array metadata")
        }
    }

    func validateOwnedReceive(_ array: MLXArray) throws {
        try validateMetadata(array)
        let bound = try Memory.allocationFootprintUpperBound(byteCount: byteCount)
        guard let storage = try array.evaluatedBufferInfo(), storage.isUnique,
            storage.isRowContiguous, storage.dataOffset == 0, storage.dataElements == elements,
            storage.allocatedBytes >= byteCount, storage.allocatedBytes <= bound else {
            throw ProbeError("Point-to-point receive is not an owned compact zero-offset allocation")
        }
    }
}
