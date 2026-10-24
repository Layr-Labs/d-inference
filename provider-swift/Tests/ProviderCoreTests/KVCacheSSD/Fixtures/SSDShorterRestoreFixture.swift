import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Scalar observations only. This fixture never retains a failed import plan,
/// tensor, manifest permit or file access on behalf of the production reader.
final class SSDShorterRestoreProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var endpoints: [Int] = []
    private var evaluations: [Int] = []
    private var started = 0
    private var released = 0
    private var completed = false

    var positions: [Int] { lock.withLock { endpoints } }
    var evaluatedPositions: [Int] { lock.withLock { evaluations } }
    var scratchCounts: (Int, Int) { lock.withLock { (started, released) } }
    var stageCompleted: Bool { lock.withLock { completed } }
    func record(_ position: Int) { lock.withLock { endpoints.append(position) } }
    func evaluated(_ position: Int) { lock.withLock { evaluations.append(position) } }
    func didCompleteStage() { lock.withLock { completed = true } }

    func scratch(_ fixture: SSDHybridCheckpointTestFixture,
                 onRelease: @escaping @Sendable (Int) -> Void = { _ in }) throws -> CBv2CompleteCheckpointIOLease {
        let original = try fixture.reserveReadScratch()
        lock.withLock { started += 1 }
        return .init(reservation: .init(onRelease: { [self] in
            original.close()
            let count = lock.withLock { released += 1; return released }
            onRelease(count)
        }), usesProcessMemoryOwner: fixture.sharedPaged)
    }

    func cpuPlan(_ manifest: CBv2CompleteCheckpointManifest,
                 fixture: SSDHybridCheckpointTestFixture) throws -> CBv2CompleteCheckpointImportPlan {
        #expect(Device.defaultDevice().deviceType == .cpu)
        let plan = try fixture.plan(manifest)
        let position = manifest.position
        plan.evaluateDestinations = { [self] arrays in
            #expect(Device.defaultDevice().deviceType == .cpu)
            evaluated(position)
            try Device.withDefaultDevice(.cpu) { try withError { eval(arrays) } }
        }
        return plan
    }
}

final class SSDShorterRestoreGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        #expect(release.wait(timeout: .now() + 5) == .success, "fixture gate timed out")
    }

    func open() { release.signal() }

    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
    }

    static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }
}

enum SSDShorterRestoreFixture {
    private enum ManifestStop: Error { case done }

    /// Uses the real encrypted writer and existing fixture-volume selection.
    /// CPU is selected both around source evaluation and around each reader;
    /// no detached-task default device or production memory policy is assumed.
    static func withStore(
        shared: Bool = false, positions: [Int] = [256, 512],
        _ body: (SSDHybridCheckpointTestFixture, SSDHybridCheckpointStore) async throws -> Void
    ) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            let fixture = try SSDHybridCheckpointTestFixture(sharedPaged: shared, paged: true,
                tokenCount: (positions.max() ?? 512) + 1)
            let store: SSDHybridCheckpointStore
            do { store = try fixture.makeStore() }
            catch { fixture.codec.admission.closeProcessMemoryOwner(); fixture.remove(); throw error }
            do {
                for position in positions {
                    try #require(try await fixture.donate(store, receipt: UInt64(position), position: position) == [position],
                        "fixture donation must succeed under the unchanged disk floor")
                }
                #expect(store.stats().entries == positions.count)
                #expect(store.stats().stageReadBytes == 0)
                try await body(fixture, store)
            } catch {
                await store.closeAndWait()
                fixture.codec.admission.closeProcessMemoryOwner()
                fixture.remove()
                throw error
            }
            await store.closeAndWait()
            #expect(store.stats().stagedBytesInUse == 0)
            #expect(store.lock.withLock { store.reading.isEmpty && store.stages.isEmpty && store.stageReservations.isEmpty })
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.codec.admission.bytesReserved == 0)
            #expect(fixture.backend?.bytesWired == 0)
            fixture.codec.admission.closeProcessMemoryOwner()
            #expect(fixture.budget.processLedger.snapshot().chargedBytes == 0)
            #expect(fixture.budget.processLedger.snapshot().materializedBytes == 0)
            #expect(fixture.budget.processLedger.snapshot().ownerCount == 0)
            fixture.remove()
        }
    }

    /// Independently prices exactly the authenticated manifest prefix. These
    /// fixture-control reads do not touch the store's request statistics.
    static func manifestReadBytes(_ fixture: SSDHybridCheckpointTestFixture,
                                  store: SSDHybridCheckpointStore, position: Int) throws -> Int {
        var bytes = 0
        do {
            try SSDBlockStore.readStreaming(from: fixture.file(store, position: position), kekKey: fixture.key,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: store.config.maxReadBytes, maximumMetadataBytes: 1 << 20,
                maximumWrappedDEKBytes: 60, onBytesRead: { bytes += $0 },
                validateMetadata: { _ in }, consumeChunk: { index, _ in
                    #expect(index == 0)
                    throw ManifestStop.done
                })
        } catch ManifestStop.done { return bytes }
        Issue.record("fixture did not authenticate its encrypted manifest")
        return bytes
    }

    static func expectedReadBytes(_ fixture: SSDHybridCheckpointTestFixture,
                                  store: SSDHybridCheckpointStore, failed: [Int], success: Int?) throws -> Int {
        var bytes = 0
        for position in failed + (success.map { [$0] } ?? []) {
            bytes += try manifestReadBytes(fixture, store: store, position: position)
        }
        if let success { bytes += try Data(contentsOf: fixture.file(store, position: success)).count }
        return bytes
    }

    static func expectSingleStage(_ store: SSDHybridCheckpointStore, result: SSDPrefixCacheStageResult,
                                  readBytes: Int, files: Int) {
        let stats = store.stats()
        #expect(result.stageMs.isFinite && result.stageMs >= 0)
        #expect(stats.stageMilliseconds == result.stageMs,
            "one public stage call owns one cumulative elapsed time, not one duration per candidate")
        #expect(stats.filesRead == files)
        #expect(stats.stageReadBytes == readBytes && stats.bytesRead == readBytes)
        #expect(stats.stageReadBytes <= store.config.maxReadBytes)
        #expect(stats.stageConsumptions == 0 && stats.consumedPrefixTokens == 0)
        #expect(result.resolved(actualCachedTokens: 0).outcome != .hit,
            "a stage result is not native adoption or a receipt hit")
    }

    /// Cross the same native page-owner transfer used by engine adoption, then
    /// export the adopted state to check every native bit. This is not a model
    /// forward or terminal-usage/HTTP test and does not manufacture saved usage.
    static func adoptAndRetire(_ fixture: SSDHybridCheckpointTestFixture,
                               store: SSDHybridCheckpointStore, requestID: CBv2RequestID,
                               position: Int) throws {
        let backend = try #require(fixture.backend)
        let maximum = fixture.tokens.count + 8
        let staged = try #require(store.takeStaged(requestID: requestID, tokens: fixture.tokens,
            cacheSalt: "tenant-a", maximumSequenceLength: maximum))
        defer { staged.close() }
        #expect(staged.manifest.position == position)
        #expect(store.takeStaged(requestID: requestID, tokens: fixture.tokens,
            cacheSalt: "tenant-a", maximumSequenceLength: maximum) == nil)
        var recurrent: CBv2RecurrentCheckpoint?
        var active: [CBv2SequenceKV?] = []
        defer {
            recurrent = nil
            backend.release(active)
            active.removeAll()
            fixture.codec.admission.releaseAll(id: requestID)
        }
        active = try staged.consumePreparedState { prepared in
            let frame = try #require(prepared.pagedFrame)
            prepared.pagedFrame = nil
            let adoption = try backend.pool.importCheckpoint(frame, admission: fixture.codec.admission,
                requestID: requestID, layerKinds: fixture.codec.layerKinds, maximumTokens: maximum)
            defer { adoption.release() }
            return try adoption.moveToActiveRequest { auxiliary in
                recurrent = try fixture.codec.recurrentCheckpoint(manifest: staged.manifest, auxiliary: auxiliary)
            }
        }
        #expect(backend.bytesWired > 0 && fixture.codec.admission.bytesReserved > 0)
        #expect(active.compactMap { $0 }.allSatisfy { $0.absoluteOffset == position })
        let source = try fixture.codec.export(checkpoint: #require(recurrent), state: active,
            tokens: fixture.tokens, cacheSalt: "tenant-a")
        defer { source.close() }
        #expect(source.manifest.position == position)
        for (index, descriptor) in source.manifest.tensors.enumerated() {
            var value = Float(index + 1)
            let scalar = withUnsafeBytes(of: &value) { Data($0) }
            let expected = Data((0..<descriptor.byteCount).map { scalar[$0 % scalar.count] })
            #expect(try source.readSegment(tensorIndex: index, byteOffset: 0,
                maximumBytes: descriptor.byteCount) == expected)
        }
        #expect(store.stats().stageConsumptions == 1 && store.stats().consumedPrefixTokens == position)
    }
}
