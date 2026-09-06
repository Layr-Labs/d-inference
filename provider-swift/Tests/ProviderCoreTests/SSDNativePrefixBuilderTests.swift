import CryptoKit
import Foundation
import MLX
import Testing
@testable import ProviderCore

@Suite("SSD bounded native prefix fill", .serialized)
struct SSDNativePrefixBuilderTests {
    private let shape = [1, 2, 2, 3]

    private func metadata() -> SSDBlockMetadata {
        SSDBlockMetadata(
            lookupTag: String(repeating: "a", count: 64), weightHash: "fixture",
            layoutEpoch: "fixture", blockSize: 2, layerCount: 3,
            chunks: (0..<2).map {
                SSDBlockChunkDescriptor(layerIndex: 1, tensor: $0, shape: shape, dtype: "float32")
            }, chunkPlaintextSizes: [48, 48])
    }

    private func payload(block: Int, tensor: Int) -> Data {
        let values: [UInt32] = (0..<12).map {
            let special: [UInt32] = [0, 0x80000000, 0x7fc12345, 0x7f800000]
            return $0 < special.count ? special[$0] : UInt32(block * 100 + tensor * 20 + $0)
        }
        return values.withUnsafeBytes { Data($0) }
    }

    private func expected(blocks: Int, tensor: Int) -> Data {
        var result = Data()
        for head in 0..<2 {
            for block in 0..<blocks {
                let bytes = payload(block: block, tensor: tensor)
                result.append(bytes[(head * 24)..<((head + 1) * 24)])
            }
        }
        return result
    }

    private func fill(_ builder: SSDNativePrefixBuilder, block: Int) throws {
        try builder.beginBlock(metadata: metadata())
        for tensor in 0..<2 { try builder.append(chunkIndex: tensor, data: payload(block: block, tensor: tensor)) }
        try builder.commitBlock()
    }

    @Test("native fill preserves head layout and raw NaN/signed-zero bits without concatenation")
    func directFill() throws {
        let builder = try SSDNativePrefixBuilder(
            metadata: metadata(), blockSize: 2, capacityBlocks: 3, maximumDestinationBytes: 288)
        for block in 0..<3 { try fill(builder, block: block) }
        #expect(builder.destinationBytes == 288)
        #expect(builder.compactionPeakBytes == 288)
        let prefix = try builder.finish()
        #expect(prefix.count == 3)
        #expect(prefix[0] == nil && prefix[2] == nil)
        let row = try #require(prefix[1])
        #expect(row.offset == 6)
        #expect(row.keys.shape == [1, 2, 6, 3])
        #expect(row.keys.asData(access: .copy).data == expected(blocks: 3, tensor: 0))
        #expect(row.values.asData(access: .copy).data == expected(blocks: 3, tensor: 1))
        #expect(throws: SSDNativePrefixBuilder.Failure.closed) { try builder.finish() }
    }

    @Test("corrupt final chunk exposes only committed blocks and drops oversized backing")
    func authenticatedShortening() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        var allocationRefs: [WeakArray] = []
        let builder = try SSDNativePrefixBuilder(
            metadata: metadata(), blockSize: 2, capacityBlocks: 2, maximumDestinationBytes: 192,
            allocate: { shape, dtype in
                let array = MLXArray.zeros(shape, dtype: dtype)
                eval(array)
                allocationRefs.append(WeakArray(array))
                return array
            })
        for block in 0..<2 {
            let url = SSDBlockStore.fileURL(root: root, tag16Hex: String(repeating: block == 0 ? "a" : "b", count: 32))
            _ = try SSDBlockStore.write(
                to: url, metadata: metadata(), chunks: (0..<2).map { payload(block: block, tensor: $0) }, kekKey: key)
            if block == 1 {
                var bytes = try Data(contentsOf: url)
                bytes[bytes.count - 1] ^= 1
                try bytes.write(to: url)
            }
            do {
                try SSDBlockStore.readStreaming(
                    from: url, kekKey: key, maximumChunkBytes: 48, maximumPlaintextBytes: 96,
                    requireEOF: true,
                    validateMetadata: { try builder.beginBlock(metadata: $0) },
                    consumeChunk: { try builder.append(chunkIndex: $0, data: $1) })
                try builder.commitBlock()
                #expect(block == 0)
            } catch {
                #expect(block == 1)
            }
        }
        #expect(builder.committedBlocks == 1)
        #expect(builder.compactionPeakBytes == 240)
        let row = try #require(builder.finish()[1])
        #expect(allocationRefs.count == 4)
        #expect(allocationRefs.prefix(2).allSatisfy { $0.array == nil })
        #expect(row.keys.nbytes + row.values.nbytes == 96)
        #expect(row.keys.asData(access: .copy).data == expected(blocks: 1, tensor: 0))
        #expect(row.values.asData(access: .copy).data == expected(blocks: 1, tensor: 1))
    }

    @Test("reservation/layout rejection precedes native allocation; allocation failure drains partial targets")
    func rejectedAllocation() throws {
        var calls = 0
        var refs: [WeakArray] = []
        let allocate: ([Int], DType) throws -> MLXArray = { shape, dtype in
            calls += 1
            if calls == 2 { throw FixtureFailure.injected }
            let value = MLXArray.zeros(shape, dtype: dtype)
            eval(value)
            refs.append(WeakArray(value))
            return value
        }
        #expect(throws: SSDNativePrefixBuilder.Failure.insufficientReservation) {
            try SSDNativePrefixBuilder(metadata: metadata(), blockSize: 2, capacityBlocks: 2,
                                       maximumDestinationBytes: 191, allocate: allocate)
        }
        #expect(calls == 0)
        #expect(throws: (any Error).self) {
            try SSDNativePrefixBuilder(metadata: metadata(), blockSize: 2, capacityBlocks: Int.max,
                                       maximumDestinationBytes: Int.max, allocate: allocate)
        }
        #expect(calls == 0)
        #expect(throws: SSDNativePrefixBuilder.Failure.allocationFailed) {
            try SSDNativePrefixBuilder(metadata: metadata(), blockSize: 2, capacityBlocks: 2,
                                       maximumDestinationBytes: 192, allocate: allocate)
        }
        #expect(calls == 2)
        #expect(refs.allSatisfy { $0.array == nil })
    }

    @Test("close discards a partial private destination and cannot publish it")
    func closePartial() throws {
        var refs: [WeakArray] = []
        let builder = try SSDNativePrefixBuilder(
            metadata: metadata(), blockSize: 2, capacityBlocks: 2, maximumDestinationBytes: 192,
            allocate: { shape, dtype in
                let array = MLXArray.zeros(shape, dtype: dtype)
                eval(array)
                refs.append(WeakArray(array))
                return array
            })
        try builder.beginBlock(metadata: metadata())
        try builder.append(chunkIndex: 0, data: payload(block: 0, tensor: 0))
        #expect(throws: (any Error).self) { try builder.append(chunkIndex: 0, data: payload(block: 0, tensor: 0)) }
        #expect(throws: SSDNativePrefixBuilder.Failure.incomplete) { try builder.commitBlock() }
        builder.close()
        builder.close()
        #expect(refs.allSatisfy { $0.array == nil })
        #expect(throws: SSDNativePrefixBuilder.Failure.closed) { try builder.finish() }
    }

    @Test("cancelled compaction allocates nothing and drops its source on close")
    func cancellationBeforeCompaction() throws {
        var cancelled = false
        var refs: [WeakArray] = []
        let builder = try SSDNativePrefixBuilder(
            metadata: metadata(), blockSize: 2, capacityBlocks: 2, maximumDestinationBytes: 192,
            checkCancellation: { if cancelled { throw CancellationError() } },
            allocate: { shape, dtype in
                let array = MLXArray.zeros(shape, dtype: dtype)
                eval(array)
                refs.append(WeakArray(array))
                return array
            })
        try fill(builder, block: 0)
        cancelled = true
        #expect(throws: CancellationError.self) { try builder.finish() }
        #expect(refs.count == 2)
        builder.close()
        #expect(refs.allSatisfy { $0.array == nil })
    }

    @Test("large staging scratch is constant and overflow fails before reservation")
    func boundedPeak() {
        let gib = 1_024 * 1_024 * 1_024
        #expect(SSDNativePrefixBuilder.stagingPeakBytes(runBytes: gib) == gib + 68 * 1_024 * 1_024)
        #expect(SSDNativePrefixBuilder.stagingPeakBytes(runBytes: 2 * gib) == 2 * gib + 68 * 1_024 * 1_024)
        #expect(SSDNativePrefixBuilder.stagingPeakBytes(runBytes: Int.max) == nil)
        #expect(SSDNativePrefixBuilder.stagingPeakBytes(runBytes: 0) == nil)
    }
}

private final class WeakArray {
    weak var array: MLXArray?
    init(_ array: MLXArray) { self.array = array }
}
private enum FixtureFailure: Error { case injected }
