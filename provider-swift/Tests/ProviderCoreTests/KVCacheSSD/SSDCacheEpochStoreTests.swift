import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

private actor EpochOpenState {
    private var complete = false

    func markComplete() {
        complete = true
    }

    var isComplete: Bool { complete }
}

@Suite("SSD cache epoch persistence")
struct SSDCacheEpochStoreTests {
    @Test("epoch persists, rotates durably, and binding drift wipes blocks")
    func lifecycle() throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalBinding = binding(contract: String(repeating: "b", count: 64))
        let first = try SSDCacheEpochStore(root: root, binding: originalBinding)
        let firstEpoch = try #require(first.current)
        let reopened = try SSDCacheEpochStore(root: root, binding: originalBinding)
        #expect(reopened.current == firstEpoch)
        #expect(first.takeNextSequence(expectedEpoch: firstEpoch) == 1)
        #expect(reopened.takeNextSequence(expectedEpoch: firstEpoch) == 2)

        let rotatedEpoch = try #require(first.rotate())
        #expect(rotatedEpoch != firstEpoch)
        #expect(reopened.current == nil)
        #expect(reopened.takeNextSequence(expectedEpoch: rotatedEpoch) == nil)
        #expect(first.takeNextSequence(expectedEpoch: firstEpoch) == nil)
        #expect(first.takeNextSequence(expectedEpoch: rotatedEpoch) == 1)
        #expect(try SSDCacheEpochStore(root: root, binding: originalBinding).current == rotatedEpoch)

        let block = SSDBlockStore.fileURL(
            root: root,
            tag16Hex: String(repeating: "c", count: 32))
        try FileManager.default.createDirectory(
            at: block.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: block)
        #expect(FileManager.default.fileExists(atPath: block.path))

        let changed = try SSDCacheEpochStore(
            root: root,
            binding: binding(contract: String(repeating: "d", count: 64)))
        #expect(changed.current != rotatedEpoch)
        #expect(first.current == nil)
        #expect(!FileManager.default.fileExists(atPath: block.path))
    }

    @Test("frozen-full layout epoch purges snap-2 blocks before publication")
    func frozenReplayEpochRotation() throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-frozen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let old = try SSDCacheEpochStore(
            root: root,
            binding: binding(
                contract: String(repeating: "b", count: 64),
                layout: "cbv2-snap-2|f16|256|deadbeef"))
        let oldEpoch = try #require(old.current)
        let block = SSDBlockStore.fileURL(
            root: root,
            tag16Hex: String(repeating: "a", count: 32))
        try FileManager.default.createDirectory(
            at: block.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("old-semantics".utf8).write(to: block)

        let currentLayout = SSDBlockStore.layoutEpoch(
            blockSize: 256,
            layerKinds: [
                CBv2LayerKind(
                    attention: .full,
                    headDim: 64,
                    kvHeads: 8,
                    queryHeads: 64)
            ])
        #expect(currentLayout.hasPrefix("cbv2-frozen-full-3|native-fp|"))
        let current = try SSDCacheEpochStore(
            root: root,
            binding: binding(
                contract: String(repeating: "b", count: 64),
                layout: currentLayout))
        #expect(current.current != oldEpoch)
        #expect(old.current == nil)
        #expect(!FileManager.default.fileExists(atPath: block.path))
    }

    @Test("provider advertises v2 only after frozen cache scan readiness")
    func advertisementWaitsForScan() async throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-ready-frozen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kinds = [
            CBv2LayerKind(
                attention: .slidingWindow(128),
                headDim: 64,
                kvHeads: 8,
                queryHeads: 64),
            CBv2LayerKind(
                attention: .full,
                headDim: 64,
                kvHeads: 8,
                queryHeads: 64),
        ]
        let layout = SSDBlockStore.layoutEpoch(blockSize: 256, layerKinds: kinds)
        let epochStore = try SSDCacheEpochStore(
            root: root,
            binding: binding(
                contract: String(repeating: "b", count: 64),
                layout: layout))
        let cache = SSDPrefixCache(
            config: .init(
                modelId: "gpt-oss",
                promptContractID: String(repeating: "b", count: 64),
                weightHash: String(repeating: "a", count: 64),
                blockSize: 256,
                adoptionBoundTokens: 128,
                layoutEpoch: layout,
                epochStore: epochStore,
                root: root,
                ttlSeconds: 900,
                minEffectiveTokens: 1,
                maxStageBytes: 1 << 20,
                maxStageMillis: 1_000,
                nowSeconds: { 1_000 }),
            kekKey: SymmetricKey(size: .bits256),
            kvBudget: nil,
            diskBudget: SSDDiskBudget(),
            maxWriteBytesPerDay: 0,
            strictFsync: false,
            diskBudgetBytes: { 1 << 30 })
        let state = ProviderState()
        state.setPrefixCacheSnapshot(
            sources: ["gpt-oss": cache],
            statuses: [PrefixCacheModelStatus(
                modelId: "gpt-oss",
                backend: .contiguous,
                replayStrategy: .frozenFull,
                state: .pending,
                reason: .scanPending)],
            runtimeIdentityAvailable: true)
        #expect(state.prefixCacheV2Advertisement().protocolVersion == 1)
        #expect(state.prefixCacheV2Advertisement().models.isEmpty)
        #expect(state.prefixCacheV2Advertisement().statuses.first?.state == .pending)
        #expect(state.prefixCacheV2Advertisement().statuses.first?.reason == .scanPending)

        cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)
        for _ in 0 ..< 100
        where state.prefixCacheV2Advertisement().protocolVersion != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = state.prefixCacheV2Advertisement()
        #expect(ready.protocolVersion == 2)
        #expect(ready.models.map(\.modelId) == ["gpt-oss"])
        #expect(ready.models.allSatisfy { $0.ready })
        #expect(ready.statuses.first?.state == .ready)
        #expect(ready.statuses.first?.reason == .ready)

        state.setPrefixCacheSnapshot(
            sources: ["gpt-oss": cache],
            statuses: [PrefixCacheModelStatus(
                modelId: "gpt-oss",
                backend: .unknown,
                replayStrategy: .none,
                state: .ready,
                reason: .ready)],
            runtimeIdentityAvailable: true)
        let unknown = state.prefixCacheV2Advertisement()
        #expect(unknown.protocolVersion == 1)
        #expect(unknown.models.isEmpty)
        #expect(unknown.statuses.isEmpty)

        state.setPrefixCacheSnapshot(
            sources: ["gpt-oss": cache],
            statuses: [],
            runtimeIdentityAvailable: true)
        let missing = state.prefixCacheV2Advertisement()
        #expect(missing.protocolVersion == 1)
        #expect(missing.models.isEmpty)

        state.setPrefixCacheSnapshot(
            sources: ["gpt-oss": cache],
            statuses: [PrefixCacheModelStatus(
                modelId: "gpt-oss",
                backend: .contiguous,
                replayStrategy: .frozenFull,
                state: .ready,
                reason: .ready)],
            runtimeIdentityAvailable: true)
        await cache.closeAndWait()
        #expect(state.prefixCacheV2Advertisement().protocolVersion == 1)
    }

    @Test("epoch metadata symlink is rejected without following it")
    func rejectsSymlink() throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-symlink-\(UUID().uuidString)", isDirectory: true)
        let outside = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("cache-epoch.json"),
            withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            _ = try SSDCacheEpochStore(root: root, binding: binding(
                contract: String(repeating: "b", count: 64)))
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("missing runtime identity explains protocol-v1 status")
    func runtimeIdentityGateIsReported() {
        let state = ProviderState()
        state.setPrefixCacheSnapshot(
            sources: [:],
            statuses: [PrefixCacheModelStatus(
                modelId: "model",
                backend: .contiguous,
                replayStrategy: .direct,
                state: .pending,
                reason: .scanPending)],
            runtimeIdentityAvailable: false)
        let snapshot = state.prefixCacheV2Advertisement()
        #expect(snapshot.protocolVersion == 1)
        #expect(snapshot.statuses.first?.state == .disabled)
        #expect(snapshot.statuses.first?.reason == .runtimeIdentityUnavailable)
    }

    @Test("interrupted binding rebuild cannot publish its invalidating epoch")
    func interruptedBindingRebuildRetriesWipe() throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-rebuild-\(UUID().uuidString)", isDirectory: true)
        let outside = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-rebuild-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let originalBinding = binding(contract: String(repeating: "b", count: 64))
        let original = try SSDCacheEpochStore(root: root, binding: originalBinding)
        let originalEpoch = try #require(original.current)
        let unsafeFanout = root.appendingPathComponent("aa", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: unsafeFanout, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            _ = try SSDCacheEpochStore(
                root: root,
                binding: binding(contract: String(repeating: "d", count: 64)))
        }
        #expect(original.current == nil)

        try FileManager.default.removeItem(at: unsafeFanout)
        let recovered = try SSDCacheEpochStore(root: root, binding: originalBinding)
        #expect(recovered.current != originalEpoch)
    }

    @Test("unloaded deletion blocks reopen and keeps the epoch and sequence")
    func unloadedDeletionSerializesReopen() async throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-unloaded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = binding(contract: String(repeating: "b", count: 64))
        let original = try SSDCacheEpochStore(root: root, binding: binding)
        let originalEpoch = try #require(original.current)
        #expect(original.takeNextSequence(expectedEpoch: originalEpoch) == 1)
        let (entered, enteredContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let mutation = Task.detached {
            SSDCacheEpochStore.performUnloadedDestructiveChange(root: root) {
                enteredContinuation.yield(())
                release.wait()
            }
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()
        // Per-file deletion on an unloaded root neither suspends nor
        // replaces the generation; it only holds the initialization lock.
        #expect(original.current == originalEpoch)

        let openState = EpochOpenState()
        let reopen = Task.detached {
            let store = try SSDCacheEpochStore(root: root, binding: binding)
            await openState.markComplete()
            return store
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(await openState.isComplete))

        release.signal()
        #expect(await mutation.value)
        let reopened = try await reopen.value
        #expect(reopened.current == originalEpoch)
        #expect(original.current == originalEpoch)
        #expect(reopened.takeNextSequence(expectedEpoch: originalEpoch) == 2)
    }

    @Test("unloaded deletion refuses an unreadable epoch record and runs without one")
    func unloadedDeletionRecordGate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-epoch-unloaded-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var ran = 0
        #expect(SSDCacheEpochStore.performUnloadedDestructiveChange(root: root) { ran += 1 })
        #expect(ran == 1)
        let record = root.appendingPathComponent("cache-epoch.json")
        try Data("not json".utf8).write(to: record)
        #expect(!SSDCacheEpochStore.performUnloadedDestructiveChange(root: root) { ran += 1 })
        #expect(ran == 1)
        #expect(try Data(contentsOf: record) == Data("not json".utf8), "the record is never rewritten")
    }

    @Test("the rebuild wipe treats an already-missing block as removed and still rejects a replacement")
    func staleBlockRemovalToleratesMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-epoch-stale-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-epoch-stale-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let block = SSDBlockStore.fileURL(
            root: root, tag16Hex: String(repeating: "c", count: 32))
        try FileManager.default.createDirectory(
            at: block.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Listed by the wipe, then unlinked by a superseded instance's
        // per-file removal before the wipe reached it.
        try SSDCacheEpochStore.removeStaleBlock(at: block, under: root)

        try Data("stale".utf8).write(to: block)
        try SSDCacheEpochStore.removeStaleBlock(at: block, under: root)
        #expect(!FileManager.default.fileExists(atPath: block.path))

        // Present but not an owned regular file: the rebuild must still fail
        // rather than advertise a fresh epoch over an entry it could not clear.
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: block, withDestinationURL: outside)
        #expect(throws: SSDBlockStoreError.self) {
            try SSDCacheEpochStore.removeStaleBlock(at: block, under: root)
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("a binding rebuild survives a superseded instance unlinking blocks during the wipe")
    func rebuildSurvivesConcurrentUnlink() async throws {
        for _ in 0 ..< 2 {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cache-epoch-race-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = try SSDCacheEpochStore(
                root: root, binding: binding(contract: String(repeating: "b", count: 64)))
            let originalEpoch = try #require(original.current)
            let fanout = root.appendingPathComponent("aa", isDirectory: true)
            try FileManager.default.createDirectory(at: fanout, withIntermediateDirectories: true)
            for index in 0 ..< 400 {
                let name = "aa" + String(repeating: "0", count: 22)
                    + String(format: "%08x", index) + ".dbk3"
                try Data("stale".utf8).write(to: fanout.appendingPathComponent(name))
            }

            // The racer stands in for a superseded instance whose removal
            // already passed its ownership check. It starts when the rebuild
            // has replaced the record (written immediately before the wipe)
            // and unlinks from the far end of the listing, so the two passes
            // meet on blocks the wipe listed but has not reached.
            let record = root.appendingPathComponent("cache-epoch.json")
            let racer = Task.detached { () -> Int in
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if let data = try? Data(contentsOf: record),
                        let text = String(data: data, encoding: .utf8),
                        !text.contains(originalEpoch)
                    { break }
                }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: fanout.path)) ?? []
                var unlinked = 0
                for name in names.reversed() where name.hasSuffix(".dbk3") {
                    if unlink(fanout.appendingPathComponent(name).path) == 0 { unlinked += 1 }
                }
                return unlinked
            }

            let rebuilt = try SSDCacheEpochStore(
                root: root, binding: binding(contract: String(repeating: "d", count: 64)))
            _ = await racer.value
            let rotated = try #require(rebuilt.current)
            #expect(rotated != originalEpoch)
            #expect(original.current == nil)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: fanout.path)
            #expect(remaining.filter { $0.hasSuffix(".dbk3") }.isEmpty)
        }
    }

    @Test("epoch record accepts its size limit and rejects one extra byte")
    func boundedRecord() throws {
        let root = try SSDTestDirectory.parent()
            .appendingPathComponent("cache-epoch-bounded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = binding(contract: String(repeating: "b", count: 64))
        let original = try SSDCacheEpochStore(root: root, binding: binding)
        let epoch = try #require(original.current)
        let record = root.appendingPathComponent("cache-epoch.json")
        var bytes = try Data(contentsOf: record)
        bytes.append(Data(repeating: 0x20, count: 64 * 1024 - bytes.count))
        try bytes.write(to: record)
        #expect(try SSDCacheEpochStore(root: root, binding: binding).current == epoch)
        bytes.append(0x20)
        try bytes.write(to: record)
        #expect(throws: SSDBlockStoreError.self) {
            _ = try SSDCacheEpochStore(root: root, binding: binding)
        }
        #expect(try Data(contentsOf: record) == bytes)
    }

    private func binding(
        contract: String,
        layout: String = "layout"
    ) -> SSDCacheEpochStore.Binding {
        SSDCacheEpochStore.Binding(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: contract,
            blockHashVersion: "dbk3",
            blockSize: 256,
            layoutEpoch: layout,
            keyFingerprint: String(repeating: "e", count: 64))
    }
}
