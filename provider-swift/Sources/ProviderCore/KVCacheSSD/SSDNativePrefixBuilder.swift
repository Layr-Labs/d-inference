import Cmlx
import Foundation
import MLX

/// One evaluated destination per tensor, filled only by authenticated chunks.
/// Destinations remain private until all blocks in the returned prefix commit.
/// A corrupt suffix is compacted before publication, so its unused backing is
/// never hidden behind the shorter prefix's logical byte count.
final class SSDNativePrefixBuilder {
    typealias Prefix = [(keys: MLXArray, values: MLXArray, offset: Int)?]
    enum Failure: Error, Equatable { case allocationFailed, insufficientReservation, incomplete, closed }

    static let maximumChunkBytes = 16 * 1_024 * 1_024
    static let maximumMetadataBytes = 1_024 * 1_024
    private static let dtypeByName = Dictionary(
        uniqueKeysWithValues: DType.allCases.map { (String(describing: $0), $0) })

    /// Encoded run bytes bound the final native payload. Crypto holds bounded
    /// ciphertext/plaintext and header buffers, independent of prefix length.
    static func stagingPeakBytes(runBytes: Int) -> Int? {
        guard runBytes > 0 else { return nil }
        let scratch = 4 * min(runBytes, maximumChunkBytes)
            + 4 * min(runBytes, maximumMetadataBytes)
        let (peak, overflow) = runBytes.addingReportingOverflow(scratch)
        return overflow ? nil : peak
    }

    private let descriptors: [SSDBlockChunkDescriptor]
    private let chunkBytes: [Int]
    private let dtypes: [DType]
    private let layerCount: Int
    private let blockSize: Int
    private let capacityTokens: Int
    private let allocate: ([Int], DType) throws -> MLXArray
    private let checkCancellation: () throws -> Void
    private var arrays: [MLXArray] = []
    private var nextChunk = 0
    private(set) var committedBlocks = 0
    let destinationBytes: Int

    init(
        metadata: SSDBlockMetadata, blockSize: Int, capacityBlocks: Int,
        maximumDestinationBytes: Int,
        checkCancellation: @escaping () throws -> Void = {},
        allocate: @escaping ([Int], DType) throws -> MLXArray = SSDNativePrefixBuilder.allocate
    ) throws {
        guard blockSize > 0, capacityBlocks > 0,
            metadata.blockSize == blockSize,
            metadata.layerCount > 0, metadata.layerCount <= 4_096,
            !metadata.chunks.isEmpty, metadata.chunks.count % 2 == 0,
            metadata.chunks.count <= metadata.layerCount * 2,
            metadata.chunkPlaintextSizes.count == metadata.chunks.count
        else { throw Self.invalidLayout() }
        let (tokens, tokenOverflow) = blockSize.multipliedReportingOverflow(by: capacityBlocks)
        guard !tokenOverflow, tokens <= Int(Int32.max) else { throw Self.invalidLayout() }
        var dtypes: [DType] = []
        var total = 0
        var layers = Set<Int>()
        for (index, descriptor) in metadata.chunks.enumerated() {
            guard descriptor.shape.count == 4, descriptor.shape[0] == 1,
                descriptor.shape[2] == blockSize,
                descriptor.shape.allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }),
                (0..<metadata.layerCount).contains(descriptor.layerIndex),
                descriptor.tensor == index % 2,
                let dtype = Self.dtypeByName[descriptor.dtype]
            else { throw Self.invalidLayout() }
            if index % 2 == 0 {
                guard layers.insert(descriptor.layerIndex).inserted else { throw Self.invalidLayout() }
            } else {
                guard descriptor.layerIndex == metadata.chunks[index - 1].layerIndex else {
                    throw Self.invalidLayout()
                }
            }
            var bytes = dtype.size
            for dimension in descriptor.shape {
                let (next, overflow) = bytes.multipliedReportingOverflow(by: dimension)
                guard !overflow else { throw Self.invalidLayout() }
                bytes = next
            }
            guard bytes == metadata.chunkPlaintextSizes[index], bytes <= Self.maximumChunkBytes else {
                throw Self.invalidLayout()
            }
            let (native, nativeOverflow) = bytes.multipliedReportingOverflow(by: capacityBlocks)
            let (next, totalOverflow) = total.addingReportingOverflow(native)
            guard !nativeOverflow, !totalOverflow else { throw Self.invalidLayout() }
            total = next
            dtypes.append(dtype)
        }
        guard total <= maximumDestinationBytes else { throw Failure.insufficientReservation }
        self.descriptors = metadata.chunks
        self.chunkBytes = metadata.chunkPlaintextSizes
        self.dtypes = dtypes
        self.layerCount = metadata.layerCount
        self.blockSize = blockSize
        self.capacityTokens = tokens
        self.destinationBytes = total
        self.allocate = allocate
        self.checkCancellation = checkCancellation
        do {
            for (index, descriptor) in descriptors.enumerated() {
                try checkCancellation()
                var shape = descriptor.shape
                shape[2] = capacityTokens
                arrays.append(try allocate(shape, dtypes[index]))
            }
        } catch {
            arrays.removeAll()
            if error is CancellationError { throw error }
            throw Failure.allocationFailed
        }
    }

    func beginBlock(metadata: SSDBlockMetadata) throws {
        guard !arrays.isEmpty else { throw Failure.closed }
        guard nextChunk == 0, committedBlocks < capacityTokens / blockSize,
            metadata.blockSize == blockSize, metadata.layerCount == layerCount,
            metadata.chunks == descriptors, metadata.chunkPlaintextSizes == chunkBytes
        else { throw Self.invalidLayout() }
    }

    func append(chunkIndex: Int, data: Data) throws {
        guard !arrays.isEmpty else { throw Failure.closed }
        guard chunkIndex == nextChunk, descriptors.indices.contains(chunkIndex),
            data.count == chunkBytes[chunkIndex], committedBlocks < capacityTokens / blockSize
        else { throw Self.invalidLayout() }
        guard let pointer = mlx_array_data_uint8(arrays[chunkIndex].ctx) else {
            throw Failure.allocationFailed
        }
        let descriptor = descriptors[chunkIndex]
        let bytesPerToken = descriptor.shape[3] * dtypes[chunkIndex].size
        let blockHeadBytes = blockSize * bytesPerToken
        let destinationHeadBytes = capacityTokens * bytesPerToken
        let destination = UnsafeMutableRawPointer(mutating: pointer)
        data.withUnsafeBytes { source in
            for head in 0..<descriptor.shape[1] {
                destination.advanced(by: head * destinationHeadBytes + committedBlocks * blockHeadBytes)
                    .copyMemory(from: source.baseAddress!.advanced(by: head * blockHeadBytes),
                                byteCount: blockHeadBytes)
            }
        }
        nextChunk += 1
    }

    /// Called only after the entire file, including its final authentication
    /// check, succeeds. Bytes from a torn block cannot become a valid endpoint.
    func commitBlock() throws {
        guard nextChunk == descriptors.count else { throw Failure.incomplete }
        committedBlocks += 1
        nextChunk = 0
    }

    var compactionPeakBytes: Int? {
        guard committedBlocks * blockSize < capacityTokens else { return destinationBytes }
        let largestCompact = (chunkBytes.max() ?? 0) * committedBlocks
        let (peak, overflow) = destinationBytes.addingReportingOverflow(largestCompact)
        return overflow ? nil : peak
    }

    func finish() throws -> Prefix {
        guard !arrays.isEmpty else { throw Failure.closed }
        guard committedBlocks > 0 else { throw Failure.incomplete }
        let matched = committedBlocks * blockSize
        if matched < capacityTokens {
            // The caller retains the original reservation plus one compact
            // tensor until each replacement has dropped its larger backing.
            for index in arrays.indices {
                try checkCancellation()
                let descriptor = descriptors[index]
                var shape = descriptor.shape
                shape[2] = matched
                let compact: MLXArray
                do { compact = try allocate(shape, dtypes[index]) }
                catch { throw Failure.allocationFailed }
                guard let source = mlx_array_data_uint8(arrays[index].ctx),
                    let destination = mlx_array_data_uint8(compact.ctx)
                else { throw Failure.allocationFailed }
                let bytesPerToken = descriptor.shape[3] * dtypes[index].size
                let headBytes = matched * bytesPerToken
                for head in 0..<descriptor.shape[1] {
                    UnsafeMutableRawPointer(mutating: destination).advanced(by: head * headBytes)
                        .copyMemory(from: UnsafeRawPointer(source).advanced(by: head * capacityTokens * bytesPerToken),
                                    byteCount: headBytes)
                }
                arrays[index] = compact
            }
        }
        var result: Prefix = Array(repeating: nil, count: layerCount)
        for index in stride(from: 0, to: descriptors.count, by: 2) {
            result[descriptors[index].layerIndex] = (arrays[index], arrays[index + 1], matched)
        }
        close()
        return result
    }

    func close() { arrays.removeAll(keepingCapacity: false) }

    static func allocate(shape: [Int], dtype: DType) throws -> MLXArray {
        try withError { error in
            let value = MLXArray.zeros(shape, dtype: dtype)
            try error.check()
            eval(value)
            try error.check()
            guard mlx_array_data_uint8(value.ctx) != nil else { throw Failure.allocationFailed }
            return value
        }
    }

    private static func invalidLayout() -> SSDBlockStoreError {
        .malformedHeader("invalid or inconsistent native KV block layout")
    }
}
