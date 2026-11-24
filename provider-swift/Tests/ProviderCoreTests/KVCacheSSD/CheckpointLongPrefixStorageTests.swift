import CryptoKit
import Foundation
@testable import MLXLMCommon
import Testing

@testable import ProviderCore

/// MLXLMCommon encodes a complete checkpoint's prefix as a JSON array up to
/// `packedPrefixTokenThreshold` tokens and bit-packed past it, and decodes
/// each length from that one form only. A stored manifest holds a digest in
/// place of the prefix, so a read must rebuild the prefix in the same form.
/// Recurrent checkpoints sit on 256-token boundaries: 65,536 is the threshold
/// itself (a JSON array), 65,792 the first boundary past it, 87,040 an 87K
/// prompt's. The diffusion layout, packed at every length, may sit anywhere.
@Suite("Complete checkpoints past the packed-prefix threshold", .serialized)
struct CheckpointLongPrefixStorageTests {
    private static let threshold = CBv2CompleteCheckpointManifest.packedPrefixTokenThreshold

    /// The stored chunk 0 carries the digest only, whatever the prefix length:
    /// no token member, and none of the SDK's packed prefix bytes.
    private func expectNoTokenMembers(_ stored: Data, of manifest: CBv2CompleteCheckpointManifest) throws {
        let text = try #require(String(data: stored, encoding: .utf8))
        #expect(text.contains("\"prefixDigest\""))
        #expect(!text.contains("prefixTokens"), "a token member was stored")
        let sdk = try #require(JSONSerialization.jsonObject(with: manifest.storageEncoding()) as? [String: Any])
        if let packed = (sdk["packedPrefixTokens"] as? [String: Any])?["bytes"] as? String {
            let middle = packed.index(packed.startIndex, offsetBy: packed.count / 2)
            #expect(!text.contains(String(packed[middle...].prefix(64))), "packed prefix bytes were stored")
        }
    }

    /// Stores `manifest`, then rebuilds it from the prompt the way every read
    /// does (restore, chain read, duplicate validation).
    private func roundTrip(_ manifest: CBv2CompleteCheckpointManifest, prompt: [Int]) throws {
        let keys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
        let stored = try SSDHybridCheckpointEnvelope.storedManifestBytes(manifest, lookupKeys: keys)
        try expectNoTokenMembers(stored, of: manifest)
        let decoded = try SSDHybridCheckpointEnvelope.decodeManifest(stored, promptTokens: prompt, lookupKeys: keys)
        #expect(decoded == manifest)
        // The rebuilt prefix is in the SDK's own encoding, byte for byte.
        #expect(try decoded.storageEncoding() == manifest.storageEncoding())
        // Re-encoding the rebuilt manifest gives the stored chunk 0 again,
        // which duplicate validation and chain reads compare byte for byte.
        #expect(try SSDHybridCheckpointEnvelope.storedManifestBytes(decoded, lookupKeys: keys) == stored)
        let envelope = try SSDHybridCheckpointEnvelope(
            manifest: decoded, lookupKeys: keys, maximumPlaintextBytes: 1 << 30)
        #expect(envelope.manifestBytes == stored)
    }

    @Test("a recurrent checkpoint's manifest round-trips on both sides of the threshold",
          arguments: [false, true], [65_536, 65_792, 87_040])
    func recurrentManifestRoundTrips(paged: Bool, position: Int) throws {
        let fixture = try SSDHybridCheckpointTestFixture(paged: paged, tokenCount: position + 1)
        defer { fixture.remove() }
        #expect(Self.threshold == 65_536)
        let manifest = try fixture.manifest(position: position)
        let packed = try #require(String(data: manifest.storageEncoding(), encoding: .utf8))
            .contains("packedPrefixTokens")
        #expect(packed == (position > Self.threshold))
        try roundTrip(manifest, prompt: fixture.tokens)
    }

    @Test("a diffusion checkpoint's manifest, always packed, still round-trips",
          arguments: [65_536, 65_537, 87_000])
    func diffusionManifestRoundTrips(position: Int) throws {
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: String(repeating: "a", count: 64),
            promptContractID: String(repeating: "b", count: 64), buildID: String(repeating: "c", count: 64),
            numericsFingerprint: String(repeating: "d", count: 64))
        let tensors = try [position, 16].enumerated().flatMap { layer, rows in
            try [CBv2CheckpointTensorRole.keys, .values].map {
                try CBv2CheckpointTensorDescriptor(role: $0, layer: layer, shape: [1, 1, rows, 8], dtype: .bfloat16)
            }
        }
        let prompt = (0...position).map { 262_000 + $0 % 207 }
        let manifest = CBv2CompleteCheckpointManifest(identity: identity, position: position, chunkSize: 1,
            prefixTokens: Array(prompt.prefix(position)), cacheSalt: "tenant-a",
            assistantCodecID: nil, tensors: tensors,
            backendLayout: CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            nativeBlockState: .init(windowPhysicalLength: 16, windowCursor: 16))
        try roundTrip(manifest, prompt: prompt)
    }

    @Test("a long checkpoint restores, and a second donation reuses its file instead of rewriting it",
          arguments: [65_536, 65_792, 87_040])
    func longCheckpointRestoresAndIsReused(position: Int) async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: position + 1)
        defer { fixture.remove() }
        let store = try fixture.makeStore(readCap: 64 << 20)
        #expect(try await fixture.donate(store, position: position) == [position])
        let file = fixture.file(store, position: position)
        let before = try Data(contentsOf: file)

        // Duplicate validation decodes the stored manifest against the prompt.
        #expect(try await fixture.donate(store, receipt: 11, position: position) == [position])
        #expect(try Data(contentsOf: file) == before)
        #expect(store.stats().filesWritten == 1)
        #expect(store.stats().filesRead == 1)
        #expect(store.stats().corruptDropped == 0)
        #expect(store.stats().entries == 1)

        // A restore decodes it again and rebuilds the prefix from the prompt.
        let request = fixture.request()
        let staged = await store.stage(requestID: .init(12), request: request,
                                       reserveReadScratch: fixture.reserveReadScratch) { manifest in
            try fixture.codec.plan(manifest: manifest, request: request)
        }
        #expect(staged.staged)
        let checkpoint = try #require(store.takeStaged(
            requestID: .init(12), tokens: fixture.tokens, cacheSalt: "tenant-a",
            maximumSequenceLength: fixture.tokens.count + request.maxTokens))
        #expect(checkpoint.manifest.position == position)
        #expect(checkpoint.manifest.prefixTokens == Array(fixture.tokens.prefix(position)))
        checkpoint.close()
        #expect(store.stats().corruptDropped == 0)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
    }
}
