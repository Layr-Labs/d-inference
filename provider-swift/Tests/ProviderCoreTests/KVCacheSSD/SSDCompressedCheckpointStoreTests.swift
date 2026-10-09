import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Lossless complete-checkpoint store", .serialized)
struct SSDCompressedCheckpointStoreTests {
    @Test("a refused compressed checkpoint keeps its partial physical write charged after restart")
    func partialWriteBudget() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let envelope = try SSDHybridCheckpointEnvelope(manifest: fixture.manifest(), maximumPlaintextBytes: 16 << 20)
        let metadata = envelope.metadata(tag: Data(repeating: 0, count: 32), identity: fixture.identity,
            createdAt: Int64(Date().timeIntervalSince1970), chunkCodec: SSDLosslessChunkCodec.identity)
        let cap = try SSDBlockStore.minimumEncodedByteCount(metadata: metadata) + 1
        let expectedCharge = try SSDBlockStore.assembleHeader(fileIV: Data(count: 12), wrappedDEK: Data(count: 60),
            metadataJSON: SSDBlockStore.canonicalEncode(metadata), flags: 1).count + 4
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(losslessCompression: true, maxWriteBytesPerDay: cap,
            writeBudget: SSDWriteBudget(root: fixture.root), donationRecorder: outcomes, writeNowSeconds: { 0 })
        store.registerDonationDemand(.init(repeatedPrefixTokens: 256), requestID: .init(10))
        #expect(try await fixture.donate(store).isEmpty)
        #expect(outcomes.snapshot().first { $0.outcome == .writeRateLimited }?.count == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store).path))
        #expect(store.stats().filesWritten == 0)
        await store.closeAndWait()

        let reopened = try SSDWriteBudget(root: fixture.root)
        #expect(expectedCharge > 0 && expectedCharge < cap)
        #expect(reopened.admit(bytes: cap - expectedCharge, capBytesPerDay: cap, now: 0, consume: false))
        #expect(!reopened.admit(bytes: cap - expectedCharge + 1, capBytesPerDay: cap, now: 0, consume: false))
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("compression restores full native state across restart and smaller physical write cap")
    func compressedRestartAndCap() async throws {
        let baseline = try SSDHybridCheckpointTestFixture()
        defer { baseline.remove() }
        let first = try baseline.makeStore(losslessCompression: true)
        #expect(try await baseline.donate(first) == [256])
        let encodedBytes = first.stats().bytesWritten
        let nativeBytes = try baseline.manifest().validateStructure()
        #expect(encodedBytes < nativeBytes)
        await first.closeAndWait()

        // The cap fits the encoded file but cannot fit the source's native
        // tensors. The rolling-day ledger and novel bucket both charge bytes.
        let limited = try SSDHybridCheckpointTestFixture()
        defer { limited.remove() }
        let cap = max(encodedBytes + 1024, encodedBytes * 2)
        #expect(cap < nativeBytes)
        let store = try limited.makeStore(losslessCompression: true, maxWriteBytesPerDay: cap)
        #expect(try await limited.donate(store) == [256])
        #expect(store.stats().bytesWritten <= cap)
        let path = limited.file(store)
        #expect(store.stats().bytesWritten == (try Data(contentsOf: path)).count)
        await store.closeAndWait()

        // Turning the encoder off does not prevent legacy-compatible decoding
        // of an already authenticated compressed checkpoint.
        let restarted = try limited.makeStore()
        let staged = await restarted.stage(requestID: .init(77), request: limited.request(),
            reserveReadScratch: limited.reserveReadScratch, makeImportPlan: limited.plan)
        #expect(staged.staged)
        let ticket = try #require(restarted.takeStaged(requestID: .init(77), tokens: limited.tokens,
            cacheSalt: "tenant-a", maximumSequenceLength: 521))
        #expect(ticket.manifest.position == 256)
        #expect(ticket.manifest.tensors == (try limited.manifest()).tensors)
        try ticket.consumePreparedState { prepared in
            let full = try #require(prepared.state.first.flatMap { $0 } as? CBv2FullSequenceKV)
            let tensors = full.cbv2InnerState()
            #expect(tensors[0][.ellipsis, ..<256, 0...].asArray(Float.self) == Array(repeating: 1, count: 512))
            #expect(tensors[1][.ellipsis, ..<256, 0...].asArray(Float.self) == Array(repeating: 2, count: 512))
            let recurrent = try #require(prepared.checkpoint?.layers[1])
            #expect(recurrent.conv?.asArray(Float.self) == Array(repeating: 3, count: 4))
            #expect(recurrent.ssm?.asArray(Float.self) == Array(repeating: 4, count: 8))
        }
        await restarted.closeAndWait()
        #expect(await limited.budget.outstandingReservedBytes() == 0)
    }
}
