import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Suite("Bounded lossless SSD tensor compression")
struct SSDLosslessChunkCodecTests {
    @Test("native bit patterns roundtrip for every supported byte-plane width")
    func nativeBitPatterns() throws {
        for width in [1, 2, 4] {
            var native = Data()
            for index in 0..<16_384 {
                for byte in 0..<width {
                    native.append(UInt8(truncatingIfNeeded: index >> (byte * 3)))
                }
            }
            let encoded = try SSDLosslessChunkCodec.encode(native, elementBytes: width)
            #expect(encoded.count <= native.count + SSDLosslessChunkCodec.frameBytes)
            #expect(try SSDLosslessChunkCodec.decode(encoded, nativeBytes: native.count) == native)
        }
        let empty = try SSDLosslessChunkCodec.encode(Data(), elementBytes: 4)
        #expect(try SSDLosslessChunkCodec.decode(empty, nativeBytes: 0).isEmpty)
    }

    @Test("uncompressible bytes use a bounded raw fallback")
    func rawFallback() throws {
        var state: UInt64 = 0x8ad725fd943672b1
        let native = Data((0..<65_536).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        let encoded = try SSDLosslessChunkCodec.encode(native, elementBytes: 1)
        #expect(encoded.first == 0)
        #expect(encoded.count == native.count + 2)
        #expect(try SSDLosslessChunkCodec.decode(encoded, nativeBytes: native.count) == native)
    }

    @Test("malformed frames and false decoded sizes fail closed")
    func malformedFrames() throws {
        let native = Data(repeating: 0x3f, count: 4096)
        let compressed = try SSDLosslessChunkCodec.encode(native, elementBytes: 2)
        #expect(compressed.first == 1)
        for expected in [2048, 4095, 4097, 8192] {
            #expect(throws: (any Error).self) {
                try SSDLosslessChunkCodec.decode(compressed, nativeBytes: expected)
            }
        }
        for expected in [Int.max - 1, Int.max] {
            #expect(throws: (any Error).self) {
                try SSDLosslessChunkCodec.decode(Data([0, 1]), nativeBytes: expected)
            }
        }
        for malformed in [Data(), Data([0]), Data([0, 2, 0, 0]), Data([1, 3, 0]),
                          Data([9, 1]), Data(compressed.dropLast()), compressed + Data([0xff])] {
            #expect(throws: (any Error).self) {
                try SSDLosslessChunkCodec.decode(malformed, nativeBytes: native.count)
            }
        }
        #expect(throws: (any Error).self) {
            try SSDLosslessChunkCodec.encode(Data([1]), elementBytes: 2)
        }
    }

    @Test("unsupported codecs and mismatched flags never reach the plaintext sink")
    func codecBinding() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let chunks = [Data(repeating: 0x3f, count: 4096)]
        let metadata = fixture.metadata(chunks: chunks, codec: SSDLosslessChunkCodec.identity)
        _ = try SSDBlockStore.writeStreaming(to: fixture.file, metadata: metadata, kekKey: fixture.key,
            maximumChunkBytes: 4096, chunk: { chunks[$0] })
        let original = try Data(contentsOf: fixture.file)
        let handle = try FileHandle(forReadingFrom: fixture.file)
        let header = try SSDBlockStore.readHeader(from: handle)
        try handle.close()
        let body = original.suffix(from: Int(header.bodyOffset))

        for (flags, codec) in [(UInt16(0), Optional(SSDLosslessChunkCodec.identity)),
                               (1, nil), (2, SSDLosslessChunkCodec.identity), (1, "unsupported-codec")] {
            var changed = try SSDBlockStore.assembleHeader(fileIV: header.fileIV, wrappedDEK: header.wrappedDEK,
                metadataJSON: SSDBlockStore.canonicalEncode(fixture.metadata(
                    chunks: chunks, codec: codec, createdAt: metadata.createdAt)),
                flags: flags)
            changed.append(body)
            try changed.write(to: fixture.file)
            #expect(throws: (any Error).self) { try SSDBlockStore.readMetadataOnly(from: fixture.file) }
            var consumed = false
            #expect(throws: (any Error).self) {
                try SSDBlockStore.readStreaming(from: fixture.file, kekKey: fixture.key,
                    maximumChunkBytes: 4096, maximumPlaintextBytes: 4096,
                    validateMetadata: { _ in }, consumeChunk: { _, _ in consumed = true })
            }
            #expect(!consumed)
        }

        // A mutually consistent flag/metadata downgrade still changes the AAD.
        // It must fail DEK authentication before even the metadata validator.
        var downgraded = try SSDBlockStore.assembleHeader(fileIV: header.fileIV, wrappedDEK: header.wrappedDEK,
            metadataJSON: SSDBlockStore.canonicalEncode(fixture.metadata(
                chunks: chunks, codec: nil, createdAt: metadata.createdAt)))
        downgraded.append(body)
        try downgraded.write(to: fixture.file)
        var validated = false
        #expect(throws: (any Error).self) {
            try SSDBlockStore.readStreaming(from: fixture.file, kekKey: fixture.key,
                maximumChunkBytes: 4096, maximumPlaintextBytes: 4096,
                validateMetadata: { _ in validated = true }, consumeChunk: { _, _ in })
        }
        #expect(!validated)

        try FileManager.default.removeItem(at: fixture.file)
        #expect(throws: (any Error).self) {
            try SSDBlockStore.writeStreaming(to: fixture.file,
                metadata: fixture.metadata(chunks: chunks, codec: "unsupported-codec"), kekKey: fixture.key,
                maximumChunkBytes: 4096, chunk: { chunks[$0] })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test("encrypted compressed chunks restore exactly and charge actual bytes")
    func encryptedRoundtrip() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let chunks = [Data(repeating: 0x71, count: 257), Data(repeating: 0x3f, count: 262_144)]
        let metadata = fixture.metadata(chunks: chunks, codec: SSDLosslessChunkCodec.identity)
        var charged = 0
        let written = try SSDBlockStore.writeStreaming(to: fixture.file, metadata: metadata, kekKey: fixture.key,
            maximumChunkBytes: 1 << 20, elementBytes: { $0 == 0 ? 1 : 2 },
            beforeBytesWrite: { charged += $0 }, chunk: { chunks[$0] })
        #expect(charged == written)
        #expect(written < chunks.reduce(0) { $0 + $1.count } / 10)
        var restored: [Data] = []
        let observed = try SSDBlockStore.readStreaming(from: fixture.file, kekKey: fixture.key,
            maximumChunkBytes: 1 << 20, maximumPlaintextBytes: chunks.reduce(0) { $0 + $1.count },
            requireEOF: true, validateMetadata: { #expect($0 == metadata) },
            consumeChunk: { _, bytes in restored.append(bytes) })
        #expect(observed == metadata)
        #expect(restored == chunks)

        var corrupted = try Data(contentsOf: fixture.file)
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: fixture.file)
        #expect(throws: (any Error).self) { try SSDBlockStore.read(from: fixture.file, kekKey: fixture.key) }
    }

    @Test("a denied encoded write publishes no partial checkpoint")
    func interruptedWrite() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let chunks = [Data(repeating: 0x3f, count: 4096)]
        enum Refused: Error { case budget }
        var admitted = 0
        #expect(throws: Refused.self) {
            try SSDBlockStore.writeStreaming(to: fixture.file,
                metadata: fixture.metadata(chunks: chunks, codec: SSDLosslessChunkCodec.identity),
                kekKey: fixture.key, maximumChunkBytes: 4096,
                beforeBytesWrite: { bytes in
                    guard admitted == 0 else { throw Refused.budget }
                    admitted += bytes
                }, chunk: { chunks[$0] })
        }
        #expect(admitted > 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.file.deletingLastPathComponent().path).isEmpty)
    }

    @Test("legacy raw DBK3 and disabled or MiMo policy remain compatible")
    func compatibilityAndModelGate() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let chunks = [Data([0x00, 0xff, 0x7f, 0x80])]
        let metadata = fixture.metadata(chunks: chunks, codec: nil)
        let written = try SSDBlockStore.write(to: fixture.file, metadata: metadata, chunks: chunks, kekKey: fixture.key)
        #expect(written == (try SSDBlockStore.serializedByteCount(metadata: metadata)))
        #expect(try SSDBlockStore.read(from: fixture.file, kekKey: fixture.key).1 == chunks)
        #expect(!String(decoding: try SSDBlockStore.canonicalEncode(metadata), as: UTF8.self).contains("chunkCodec"))
        let enabled = [SSDPrefixCachePolicy.compressionEnvironmentFlag: "lz4"]
        for model in ["gemma-4-26b-qat-4bit", "gpt-oss-20b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "nemotron-3.5"] {
            #expect(SSDPrefixCachePolicy.losslessCompressionEnabled(modelId: model, environment: enabled))
            #expect(!SSDPrefixCachePolicy.losslessCompressionEnabled(modelId: model, environment: [:]))
        }
        for model in ["mimo-v2.6-flash", "Xiaomi/MiMo-V2.6-Flash"] {
            #expect(!SSDPrefixCachePolicy.losslessCompressionEnabled(modelId: model, environment: enabled))
        }
    }

    private struct FileFixture {
        let root: URL
        let file: URL
        let key = SymmetricKey(size: .bits256)
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ssd-lossless-\(UUID().uuidString)")
            let model = root.appendingPathComponent("012345abcdef", isDirectory: true)
            try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: model)
            file = SSDBlockStore.fileURL(root: model, tag16Hex: String(repeating: "a", count: 32))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func metadata(chunks: [Data], codec: String?,
                      createdAt: Int64 = Int64(Date().timeIntervalSince1970)) -> SSDBlockMetadata {
            .init(lookupTag: String(repeating: "a", count: 64), weightHash: "test-public-weight",
                layoutEpoch: "test-lossless", blockSize: 256, layerCount: 1,
                chunks: chunks.enumerated().map { .init(layerIndex: 0, tensor: $0.offset,
                    shape: [$0.element.count], dtype: "uint8") },
                chunkPlaintextSizes: chunks.map(\.count), createdAt: createdAt, chunkCodec: codec)
        }
    }
}
