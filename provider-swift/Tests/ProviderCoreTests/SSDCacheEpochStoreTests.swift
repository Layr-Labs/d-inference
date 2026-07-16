import Foundation
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
        let root = FileManager.default.temporaryDirectory
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

    @Test("epoch metadata symlink is rejected without following it")
    func rejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-epoch-symlink-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
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

    @Test("interrupted binding rebuild cannot publish its invalidating epoch")
    func interruptedBindingRebuildRetriesWipe() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-epoch-rebuild-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
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

    @Test("unloaded deletion blocks reopen and publishes only after mutation")
    func unloadedDeletionSerializesReopen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-epoch-unloaded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binding = binding(contract: String(repeating: "b", count: 64))
        let original = try SSDCacheEpochStore(root: root, binding: binding)
        let originalEpoch = try #require(original.current)
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
        #expect(original.current == nil)

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
        let current = try #require(reopened.current)
        #expect(current != originalEpoch)
    }

    private func binding(contract: String) -> SSDCacheEpochStore.Binding {
        SSDCacheEpochStore.Binding(
            modelId: "model",
            modelAggregateHash: String(repeating: "a", count: 64),
            promptContractId: contract,
            blockHashVersion: "dbk3",
            blockSize: 256,
            layoutEpoch: "layout",
            keyFingerprint: String(repeating: "e", count: 64))
    }
}
