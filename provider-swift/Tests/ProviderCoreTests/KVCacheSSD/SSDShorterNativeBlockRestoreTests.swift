import Foundation
import MLX
import MLXLLM
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

private final class NativeShorterPressure: @unchecked Sendable {
    private let lock = NSLock()
    private var lease: CBv2NativeBlockCheckpointLease?
    func hold(_ value: CBv2NativeBlockCheckpointLease) { lock.withLock { lease = value } }
    func release() {
        let retired = lock.withLock { let old = lease; lease = nil; return old }
        retired?.close()
    }
}

@Suite("Native-block shorter authenticated restore on CPU", .serialized)
struct SSDShorterNativeBlockRestoreTests {
    private func withStore(_ body: (NativeDiffusionCheckpointFixture, SSDHybridCheckpointStore) async throws -> Void) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            let fixture = try NativeDiffusionCheckpointFixture(rootParent: SSDTestDirectory.parent())
            defer { fixture.remove() }
            let store: SSDHybridCheckpointStore
            do { store = try fixture.makeStore() }
            catch { await fixture.engine.shutdown(); throw error }
            do {
                try #require(try await fixture.donate(store, position: 256) == [256])
                try #require(try await fixture.donate(store, position: 512) == [512])
                #expect(fixture.engine.capacity().kvBytesReserved == 0)
                try await body(fixture, store)
            } catch {
                await store.closeAndWait()
                await fixture.engine.shutdown()
                throw error
            }
            await store.closeAndWait()
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.engine.capacity().kvBytesReserved == 0)
            #expect(store.lock.withLock { store.reading.isEmpty && store.stages.isEmpty && store.stageReservations.isEmpty })
            await fixture.engine.shutdown()
        }
    }

    @Test("native-block plan and real native-reservation capacity failures restore the shorter state", arguments: ["plan", "admission"])
    func typedCapacityRestoresNativeState(_ refusal: String) async throws {
        try await withStore { fixture, store in
            let request = fixture.request(appended: true)
            let probe = SSDShorterRestoreProbe()
            let pressure = NativeShorterPressure()
            defer { pressure.release() }
            let result = await store.stageNativeBlock(requestID: .init(950), request: request, reserveReadScratch: {
                let lease = try fixture.engine.reserveNativeCheckpointReadScratch()
                return .init(reservation: .init(onRelease: {
                    lease.close()
                    pressure.release()
                }), usesProcessMemoryOwner: lease.usesProcessMemoryOwner)
            }) { manifest in
                #expect(Device.defaultDevice().deviceType == .cpu)
                probe.record(manifest.position)
                if refusal == "plan" && manifest.position == 512 {
                    throw CBv2KVError.capacityExhausted(needed: 2, available: 1)
                }
                #expect(fixture.engine.capacity().kvBytesReserved == CBv2CompleteCheckpointManifest.maximumProviderScratchBytes,
                    "failed native metadata, pressure and read-scratch owners must retire before the next plan")
                let plan = try fixture.plan(manifest, request: request)
                if refusal == "admission" && manifest.position == 512 {
                    let capacity = fixture.engine.capacity()
                    let needed = plan.nativeDestinationBytes + plan.scratchBytes
                    let bytes = capacity.kvBytesCapacity - capacity.kvBytesReserved - needed + 1
                    try #require(bytes > 0)
                    pressure.hold(try fixture.engine.reserveNativeCheckpoint(bytes: bytes))
                    #expect(fixture.engine.capacity().kvBytesCapacity - fixture.engine.capacity().kvBytesReserved == needed - 1)
                }
                return plan
            }
            #expect(probe.positions == [512, 256])
            #expect(result.stagedTokens == 256 && store.stats().filesRead == 3)
            #expect(store.stats().stageMilliseconds == result.stageMs)
            #expect(store.stats().stageReadBytes <= store.config.maxReadBytes)
            #expect(store.stats().entries == 2 && store.stats().corruptDropped == 0)
            #expect(result.resolved(actualCachedTokens: 0).outcome != .hit)
            if result.staged { try adoptAndCompare(fixture, store: store, request: request) }
        }
    }

    // Scope all adopted native aliases to this synchronous helper so its
    // caller can await owner refunds only after the borrowing state retires.
    private func adoptAndCompare(_ fixture: NativeDiffusionCheckpointFixture,
                                 store: SSDHybridCheckpointStore, request: CBv2Request) throws {
        #expect(Device.defaultDevice().deviceType == .cpu)
        let staged = try #require(store.takeNativeStaged(requestID: .init(950), tokens: request.promptTokens,
            cacheSalt: request.cacheSalt, maximumSequenceLength: request.promptTokens.count + request.maxTokens))
        #expect(staged.manifest.position == 256)
        #expect(store.takeNativeStaged(requestID: .init(950), tokens: request.promptTokens,
            cacheSalt: request.cacheSalt, maximumSequenceLength: request.promptTokens.count + request.maxTokens) == nil)
        let checkpoint = try fixture.codec.adopt(staged, prefixIdentity: fixture.prefixIdentity())
        let restored = try fixture.model.restorePrefix(checkpoint, identity: fixture.prefixIdentity(),
            promptTokenIds: MLXArray(request.promptTokens).asType(.int32).reshaped(1, request.promptTokens.count))
        let cold = try fixture.coldCache(prefixCount: 256)
        #expect(restored.snapshots().count == cold.snapshots().count)
        for (actual, expected) in zip(restored.snapshots(), cold.snapshots()) {
            #expect(actual.offset == expected.offset)
            #expect(actual.keys.asArray(Float.self).map(\.bitPattern) == expected.keys.asArray(Float.self).map(\.bitPattern))
            #expect(actual.values.asArray(Float.self).map(\.bitPattern) == expected.values.asArray(Float.self).map(\.bitPattern))
        }
        // Continue the complete next native chunk from both states. This is
        // native-block adoption, not an AR import or a manufactured hit event.
        let suffix = MLXArray(Array(request.promptTokens[256..<512])).asType(.int32).reshaped(1, 256)
        try MLX.withError { errors in
            let actual = try fixture.model.encode(tokenIds: suffix, cache: restored, encoderParameters: fixture.scalars)
            let expected = try fixture.model.encode(tokenIds: suffix, cache: cold, encoderParameters: fixture.scalars)
            try errors.check(); eval(actual, expected); try errors.check()
            #expect(actual.asArray(Float.self).map(\.bitPattern) == expected.asArray(Float.self).map(\.bitPattern))
        }
        #expect(store.stats().stageConsumptions == 1 && store.stats().consumedPrefixTokens == 256)
    }

    @Test("native-block policy, generic allocation and initial scratch refusal do not retry", arguments: ["policy", "allocation", "scratch"])
    func nonRetryableNativeRefusals(_ fault: String) async throws {
        try await withStore { fixture, store in
            let probe = SSDShorterRestoreProbe()
            let request = fixture.request()
            let result = await store.stageNativeBlock(requestID: .init(951), request: request, reserveReadScratch: {
                if fault == "scratch" { throw CBv2KVError.capacityExhausted(needed: 2, available: 1) }
                return try fixture.engine.reserveNativeCheckpointReadScratch()
            }) { manifest in
                probe.record(manifest.position)
                if fault == "allocation" { throw CBv2CompleteCheckpointError.allocationFailed }
                throw CBv2NativeBlockError.unsupportedRequest("fixture rejection")
            }
            #expect(probe.positions == (fault == "scratch" ? [] : [512]))
            #expect(result.disposition == (fault == "policy" ? .skippedPolicy : .skippedCapacity))
            #expect(store.stats().filesRead == (fault == "scratch" ? 0 : 1))
            #expect(store.stats().entries == 2 && store.stats().corruptDropped == 0 && store.stats().stages == 0)
        }
    }
}
