import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Bound media complete-checkpoint SSD identity", .serialized)
struct SSDHybridMediaIdentityTests {
    @Test func boundMediaRoundTripRejectsOtherContentTenantAndUnboundRequests() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        var kind = fixture.codec.layerKinds[0]
        kind.qwen4IndexerCompressRatio = 4
        let geometry = try CBv2Qwen4CheckpointGeometry(layer: 0, headDim: 2, compressRatio: 4,
            keyDType: .float32, pooledDType: .float32)
        let codec = CBv2CompleteCheckpointCodec(identity: fixture.identity,
            layerKinds: [kind], recurrentSpec: fixture.codec.recurrentSpec,
            kvDTypes: [.float32], assistant: nil, admission: fixture.codec.admission,
            qwen4Geometries: [geometry])
        let position = CBv2PositionState(promptPositionIds:
            MLXArray(Array(repeating: Int32(1), count: 3 * fixture.tokens.count)).reshaped([3,1,fixture.tokens.count]),
            decodeDeltas: [-2])
        let media = CBv2MultimodalInput(spans: [.init(tokenOffset: 1, length: 1)],
            attention: .causal, positionState: position, embeddings: { [] })
        var mutable = fixture.request()
        mutable.multimodal = media
        mutable.positionState = position
        mutable.hybridPrefixIdentity = try .init(digest: Data(repeating: 0x45, count: 32))
        let request = mutable
        let scope = try #require(request.checkpointCacheSalt)
        #expect(request.cacheSalt == "tenant-a" && scope != "tenant-a")
        let qsa: [CBv2CheckpointTensorDescriptor] = [
            try .init(role: .indexKeys, layer: 0, shape: [1,256,2], dtype: .float32),
            try .init(role: .indexPositions, layer: 0, shape: [3,1,256], dtype: .int32),
        ]
        let descriptors = try codec.tensorDescriptors(position: 256, qwen4: qsa, mediaTargetOnly: true)
        let manifest = CBv2CompleteCheckpointManifest(identity: fixture.identity, position: 256,
            chunkSize: 256, prefixTokens: Array(fixture.tokens.prefix(256)), cacheSalt: scope,
            assistantCodecID: nil, tensors: descriptors,
            mediaIdentity: request.hybridPrefixIdentity, mediaTargetOnly: true)
        let arrays = descriptors.enumerated().map { index, descriptor in
            MLXArray(Array(repeating: Float(index + 1), count: descriptor.shape.reduce(1,*)))
                .reshaped(descriptor.shape).asType(descriptor.dtype.mlxDType)
        }
        eval(arrays)
        let export = CBv2CompleteCheckpointExport(manifest: manifest, arrays: arrays, usesProcessMemoryOwner: false)
        let first = try fixture.makeStore()
        let written = await withCheckedContinuation { continuation in
            first.donate(export, requestID: .init(610), tokens: fixture.tokens, cacheSalt: scope) {
                continuation.resume(returning: $0)
            }
        }
        #expect(written == [256])
        await first.closeAndWait()
        let store = try fixture.makeStore()
        var unbound = request; unbound.hybridPrefixIdentity = nil
        var differentMedia = request
        differentMedia.hybridPrefixIdentity = try .init(digest: Data(repeating: 0x46, count: 32))
        var differentTenant = request; differentTenant.cacheSalt = "tenant-b"
        for (index, candidate) in [unbound, differentMedia, differentTenant].enumerated() {
            let result = await store.stage(requestID: .init(UInt64(620 + index)), request: candidate,
                reserveReadScratch: fixture.reserveReadScratch) { _ in
                Issue.record("incompatible media/tenant reached native import planning")
                throw CBv2CompleteCheckpointError.incompatibleCheckpoint
            }
            #expect(!result.staged && store.stats().filesRead == 0)
        }
        let result = await store.stage(requestID: .init(630), request: request,
            reserveReadScratch: fixture.reserveReadScratch) { manifest in
            try codec.plan(manifest: manifest, request: request, minimumChunkSize: 256, maximumChunkSize: 256)
        }
        #expect(result.staged)
        let staged = try #require(store.takeStaged(requestID: .init(630), tokens: fixture.tokens,
            cacheSalt: scope, maximumSequenceLength: fixture.tokens.count + 8))
        try staged.consumePreparedState { prepared in
            let snapshot = try #require(prepared.checkpoint?.qwen4[0])
            #expect(snapshot.positionIds.shape == [3,1,256])
            #expect(snapshot.positionIds.asArray(Int32.self) == Array(repeating: 6, count: 768))
            #expect(prepared.checkpoint?.mediaIdentity == request.hybridPrefixIdentity)
            #expect(prepared.checkpoint?.mediaTargetOnly == true)
        }
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }
}
