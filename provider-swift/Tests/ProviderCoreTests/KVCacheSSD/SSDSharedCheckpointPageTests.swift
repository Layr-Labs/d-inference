import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Shared encrypted historical checkpoints", .serialized)
struct SSDSharedCheckpointPageTests {
    @Test("page names use the derived lookup key and a separate domain")
    func lookupKeySeparation() {
        let kek = SymmetricKey(data: Data(repeating: 7, count: 32))
        let address = Data("execution/page/native-digest".utf8)
        let keys = SSDLookupKeys(kek: kek)
        let salt = "scope-a"
        var message = Data("dbkv3-complete-checkpoint-page-v1".utf8)
        var count = UInt64(salt.utf8.count).littleEndian
        withUnsafeBytes(of: &count) { message.append(contentsOf: $0) }
        message.append(contentsOf: salt.utf8)
        message.append(address)
        let lookupKey = HKDF<SHA256>.expand(pseudoRandomKey: kek,
            info: Data("dbkv3-lookup-v1".utf8), outputByteCount: 32)
        let tag = keys.checkpointPageTag(address: address, cacheSalt: salt)
        #expect(tag == Data(HMAC<SHA256>.authenticationCode(for: message, using: lookupKey)))
        #expect(tag != Data(HMAC<SHA256>.authenticationCode(for: message, using: kek)))
        #expect(tag != keys.checkpointTag(chainHash: address, cacheSalt: salt))
        #expect(tag != keys.checkpointPageTag(address: address, cacheSalt: "scope-b"))
    }

    @Test("all heads share the full prefix, disjoint native windows stay independent", arguments: [128, 1024])
    func sharingAndRetirement(window: Int) async throws {
        let fixture = try HistoricalPageFixture(window: window)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        for position in [1024, 2048, 3072] {
            #expect(try await fixture.donate(store, position: position) == [position])
            try fixture.verify(store, position: position)
        }
        let first = SSDCheckpointPageFiles.files(for: fixture.file(store, position: 1024))
        let latest = SSDCheckpointPageFiles.files(for: fixture.file(store, position: 3072))
        let shared = Set(first.map(\.physicalIdentity)).intersection(latest.map(\.physicalIdentity))
        // Two K/V tensors, two KV heads: every first-checkpoint full page shares.
        #expect(shared.count == 4)
        #expect(store.diskBytesOnDisk == SSDCheckpointPageFiles.physicalBytes(checkpoints:
            [1024, 2048, 3072].map { fixture.file(store, position: $0) }))
        #expect(store.diskBytesOnDisk < store.index.totalBytes * 3 / 4)
        #expect(store.stats().bytesWritten == store.diskBytesOnDisk)
        // Donation authenticates each endpoint's final graph, including its
        // new files. Read telemetry counts one full encoded page read per link.
        let authenticatedPageBytes = [1024, 2048, 3072].reduce(0) { total, position in
            total + SSDCheckpointPageFiles.files(for: fixture.file(store, position: position))
                .reduce(0) { $0 + $1.bytes }
        }
        #expect(store.stats().donationReadBytes == authenticatedPageBytes)
        let latestFile = fixture.file(store, position: 3072)
        let originalEpoch = store.config.epochStore?.current
        let removed = store.retireOwnedEntries([fixture.file(store, position: 1024), fixture.file(store, position: 2048)])
        #expect(removed.count == 2)
        #expect(store.config.epochStore?.current == originalEpoch)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store, position: 1024).path))
        #expect(!FileManager.default.fileExists(atPath: SSDCheckpointPageFiles.directory(for: fixture.file(store, position: 1024)).path))
        try fixture.verify(store, position: 3072)
        #expect(store.diskBytesOnDisk == SSDCheckpointPageFiles.physicalBytes(checkpoints: [latestFile]))
        await store.closeAndWait()

        let reopened = try fixture.makeStore()
        #expect(reopened.stats().entries == 1)
        try fixture.verify(reopened, position: 3072)
        let request = fixture.request()
        let staged = await reopened.stage(requestID: .init(500), request: request,
            reserveReadScratch: fixture.reserveScratch) {
                try fixture.codec.plan(manifest: $0, request: request)
            }
        #expect(staged.staged)
        let restored = try #require(reopened.takeStaged(requestID: .init(500), tokens: fixture.tokens,
            cacheSalt: "scope-a", maximumSequenceLength: fixture.tokens.count + request.maxTokens))
        #expect(restored.manifest.position == 3072)
        restored.close()
        await reopened.closeAndWait()
        #expect(reopened.stats().stagedBytesInUse == 0)
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
    }

    @Test("different execution IDs cannot share even identical native values")
    func executionIsolation() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024, receipt: 30) == [1024])
        #expect(try await fixture.donate(store, position: 2048, receipt: 31) == [2048])
        let first = SSDCheckpointPageFiles.files(for: fixture.file(store, position: 1024))
        let next = SSDCheckpointPageFiles.files(for: fixture.file(store, position: 2048))
        #expect(Set(first.map(\.physicalIdentity)).isDisjoint(with: next.map(\.physicalIdentity)))
        await store.closeAndWait()
    }

    @Test("changed bytes under a repeated submission ID cannot inherit an older page")
    func changedNativeBytes() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        #expect(try await fixture.donate(store, position: 2048, changed: true) == [2048])
        let first = SSDCheckpointPageFiles.files(for: fixture.file(store, position: 1024))
        let next = SSDCheckpointPageFiles.files(for: fixture.file(store, position: 2048))
        #expect(Set(first.map(\.physicalIdentity)).isDisjoint(with: next.map(\.physicalIdentity)))
        try fixture.verify(store, position: 2048, changed: true)
        await store.closeAndWait()
    }

    @Test("a source replaced after authentication cannot supply a trusted link")
    func sourceReplacementBeforeLink() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        let sourceFile = fixture.file(store, position: 1024)
        let envelope = try fixture.envelope(store, position: 1024)
        let reference = try #require(envelope.pages.first)
        let source = SSDCheckpointPageFiles.pageURL(checkpoint: sourceFile, id: reference.id)
        let proof = try SSDSharedCheckpointPages.readPage(at: source, reference: reference,
            key: fixture.key, identity: fixture.identity, layout: envelope.manifest.backendLayout,
            check: {}, countRead: { _ in }, consume: { _ in })

        // Exact schedule for the old gap: successful source authentication,
        // atomic replacement, then linkat's source/destination inode checks.
        try Data("replaced page".utf8).write(to: source, options: .atomic)
        #expect(!proof.matches(url: source))
        let endpoint = fixture.file(store, position: 2048)
        let target = SSDCheckpointPageFiles.pageURL(checkpoint: endpoint, id: reference.id)
        #expect(throws: (any Error).self) {
            try SSDCheckpointPageFiles.link(from: source, to: target, strictFsync: true,
                authenticate: { linked in
                    try SSDSharedCheckpointPages.readPage(at: linked, reference: reference,
                        key: fixture.key, identity: fixture.identity, layout: envelope.manifest.backendLayout,
                        check: {}, countRead: { _ in }, consume: { _ in })
                })
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        SSDCheckpointPageFiles.remove(for: endpoint)
        await store.closeAndWait()
    }

    @Test("a changed earlier page aborts graph publication and cleans partial links")
    func pageChangedBeforeManifestPublication() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let source = try fixture.source(position: 1024)
        defer { source.close() }
        let endpoint = fixture.file(store, position: 1024)
        let geometry = try SSDCheckpointPageGeometry.pages(source.manifest)
        var replaced = false
        #expect(throws: SSDAuthenticatedFileChange.self) {
            try SSDSharedCheckpointPages().write(source: source, requestID: .init(88),
                checkpoint: endpoint, tag: fixture.tag(store, position: 1024), key: fixture.key,
                strictFsync: true, createdAt: 0, maximumPlaintextBytes: 16 << 20,
                check: {
                    let files = SSDCheckpointPageFiles.files(for: endpoint)
                    guard !replaced, files.count == geometry.count,
                        let first = files.first(where: { $0.bytes > (256 * 64 * 4) }) else { return }
                    // All files exist while the final page authenticates. An
                    // earlier full-attention proof must still guard commit.
                    var bytes = try Data(contentsOf: first.url)
                    bytes[bytes.count - 1] ^= 1
                    try bytes.write(to: first.url, options: .atomic)
                    replaced = true
                }, charge: { _ in }, countRead: { _ in })
        }
        #expect(replaced)
        #expect(SSDBlockStore.indexedBlockFileStatus(at: endpoint, under: fixture.modelRoot) == .missing)
        #expect(!FileManager.default.fileExists(atPath: SSDCheckpointPageFiles.directory(for: endpoint).path))
        await store.closeAndWait()
    }

    @Test("an endpoint manifest replaced during graph read cannot validate a duplicate")
    func manifestReplacementDuringRead() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        let checkpoint = fixture.file(store, position: 1024)
        let envelope = try fixture.envelope(store, position: 1024)
        var replaced = false
        #expect(throws: SSDAuthenticatedFileChange.self) {
            try SSDSharedCheckpointPages.read(envelope: envelope, encoded: envelope.encoded(),
                checkpoint: checkpoint, tag: fixture.tag(store, position: 1024), key: fixture.key,
                maximumPlaintextBytes: 16 << 20, check: {}, countRead: { _ in }, consume: { _, _ in
                    guard !replaced else { return }
                    try Data("replaced endpoint".utf8).write(to: checkpoint, options: .atomic)
                    replaced = true
                })
        }
        #expect(replaced)
        await store.closeAndWait()
    }

    @Test("a grown shared inode is counted at its largest observed size")
    func grownSharedPageAccounting() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        #expect(try await fixture.donate(store, position: 2048) == [2048])
        let first = fixture.file(store, position: 1024)
        let second = fixture.file(store, position: 2048)
        let nextObjects = Set(SSDCheckpointPageFiles.files(for: second).map(\.physicalIdentity))
        let shared = try #require(SSDCheckpointPageFiles.files(for: first).first {
            nextObjects.contains($0.physicalIdentity)
        })
        let original = store.diskBytesOnDisk
        let handle = try FileHandle(forWritingTo: shared.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 4096))
        try handle.close()
        store.reconcileExternalRemovals()
        #expect(store.diskBytesOnDisk == original + 4096)
        #expect(store.diskBytesOnDisk == SSDCheckpointPageFiles.physicalBytes(checkpoints: [first, second]))
        _ = store.retireOwnedEntries([first])
        #expect(store.diskBytesOnDisk == SSDCheckpointPageFiles.physicalBytes(checkpoints: [second]))
        await store.closeAndWait()
    }

    @Test("an unsafe scan clears shared accounting with its index")
    func scanFailureAccounting() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        #expect(store.diskBytesOnDisk > 0)
        let fanout = fixture.file(store, position: 1024).deletingLastPathComponent()
        try Data("foreign".utf8).write(to: fanout.appendingPathComponent("not-an-owned-tag.dbk3"))
        store.scanOnDisk()
        #expect(store.index.count == 0)
        #expect(store.diskBytesOnDisk == 0)
        await store.closeAndWait()
    }

    @Test("MiMo writes the existing independent encrypted payload")
    func mimoStorageUnchanged() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore(modelID: "MiMo-V2.6")
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        let file = fixture.file(store, position: 1024)
        let metadata = try SSDBlockStore.readMetadataOnly(from: file)
        #expect(metadata.windowKind == nil)
        let directoryExists = FileManager.default.fileExists(atPath: SSDCheckpointPageFiles.directory(for: file).path)
        #expect(directoryExists == false)
        await store.closeAndWait()
    }

    @Test("missing or corrupted final pages never produce a stage or durable duplicate", arguments: [false, true])
    func corruptPage(corrupt: Bool) async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 2048) == [2048])
        let file = fixture.file(store, position: 2048)
        let envelope = try fixture.envelope(store, position: 2048)
        let reference = try #require(envelope.pages.last)
        let page = SSDCheckpointPageFiles.pageURL(checkpoint: file, id: reference.id)
        if corrupt {
            var bytes = try Data(contentsOf: page)
            bytes[bytes.count - 1] ^= 1
            try bytes.write(to: page, options: .atomic)
        } else { try FileManager.default.removeItem(at: page) }
        #expect(try await fixture.donate(store, position: 2048, receipt: 99).isEmpty)
        #expect(store.stats().corruptDropped == 1)
        #expect(store.index.count == 0)
        #expect(store.diskBytesOnDisk == 0)
        #expect(!FileManager.default.fileExists(atPath: SSDCheckpointPageFiles.directory(for: file).path))
        await store.closeAndWait()
    }

    @Test("whole-root eviction counts each inode once and preserves a survivor")
    func wholeRootBudget() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore(diskBudget: .shared)
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        #expect(try await fixture.donate(store, position: 3072) == [3072])
        let first = fixture.file(store, position: 1024)
        let last = fixture.file(store, position: 3072)
        SSDBlockStore.setAttributesIfSafe([.modificationDate: Date(timeIntervalSince1970: 100)], at: first, under: fixture.modelRoot)
        let bytes = SSDCheckpointPageFiles.physicalBytes(checkpoints: [first, last])
        let maintainer = SSDWholeRootMaintainer()
        let unchanged = maintainer.maintain(root: fixture.root, ttlSeconds: 0, nowSeconds: 200, budgetBytes: bytes)
        #expect(unchanged.budgetEvicted == 0)
        #expect(unchanged.bytesAfter == bytes)
        let single = SSDCheckpointPageFiles.physicalBytes(checkpoints: [last])
        let retired = maintainer.maintain(root: fixture.root, ttlSeconds: 0, nowSeconds: 200, budgetBytes: single)
        #expect(retired.budgetEvicted == 1)
        #expect(retired.bytesAfter == single)
        #expect(SSDBlockStore.indexedBlockFileStatus(at: first, under: fixture.modelRoot) == .missing)
        try fixture.verify(store, position: 3072)
        await store.closeAndWait()
    }

    @Test("orphan pages from a failed commit are removed without touching live links")
    func orphanRecovery() async throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        #expect(try await fixture.donate(store, position: 1024) == [1024])
        #expect(try await fixture.donate(store, position: 3072) == [3072])
        let first = fixture.file(store, position: 1024)
        #expect(SSDBlockStore.removeItemIfSafe(at: first, under: fixture.modelRoot))
        await store.closeAndWait()
        let reopened = try fixture.makeStore()
        #expect(!FileManager.default.fileExists(atPath: SSDCheckpointPageFiles.directory(for: first).path))
        try fixture.verify(reopened, position: 3072)
        await reopened.closeAndWait()
    }

    @Test("MiMo and unbounded page graphs keep the independent checkpoint representation")
    func policyAndBounds() throws {
        let fixture = try HistoricalPageFixture(window: 128)
        defer { fixture.remove() }
        let manifest = try fixture.source(position: 1024).manifest
        let mimo = SSDSharedCheckpointPages.eligible(modelID: "MiMo-V2.6", manifest: manifest,
            requestID: .init(1), maximumPlaintextBytes: 16 << 20)
        let noSubmission = SSDSharedCheckpointPages.eligible(modelID: "gpt-oss-20b", manifest: manifest,
            requestID: nil, maximumPlaintextBytes: 16 << 20)
        let tooLarge = SSDSharedCheckpointPages.eligible(modelID: "gpt-oss-20b", manifest: manifest,
            requestID: .init(1), maximumPlaintextBytes: 1)
        #expect(mimo == false)
        #expect(noSubmission == false)
        #expect(tooLarge == false)
    }
}

private final class HistoricalPageFixture: @unchecked Sendable {
    let root: URL
    let modelRoot: URL
    let key = SymmetricKey(size: .bits256)
    let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "historical-pages-weights",
        promptContractID: "historical-pages-template", buildID: "historical-pages-build", numericsFingerprint: "historical-pages-numerics")
    let tokens = (0..<4097).map { $0 % 31 }
    let codec: CBv2CompleteCheckpointCodec
    let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0,
        memorySnapshot: { .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30) })
    let window: Int

    init(window: Int) throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        self.window = window
        root = try SSDTestDirectory.parent().appendingPathComponent("shared-pages-\(UUID().uuidString)")
        modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let kinds = [CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 2, modelLayerIndex: 0),
            CBv2LayerKind(attention: .slidingWindow(window), headDim: 64, kvHeads: 2, queryHeads: 2, modelLayerIndex: 1)]
        let config = PagedKVPoolConfig(capacityBytes: 16 << 20, dtype: .float32,
            maxPrefillChunk: 256, segmentSizeBytes: 64 << 10, layerDTypes: [.float32, .float32])
        let admission = AdmissionV2(layerKinds: kinds, bytesCapacity: 64 << 20,
            config: .init(watermarkFraction: 0, elementBytes: 4), residency: CBv2PagedKVResidency(config: config))
        codec = .init(identity: identity, layerKinds: kinds, recurrentSpec: nil,
            kvDTypes: [.float32, .float32], assistant: nil, admission: admission, pagedConfig: config)
    }

    func makeStore(diskBudget: SSDDiskBudget = SSDDiskBudget(), modelID: String = "gpt-oss-20b") throws -> SSDHybridCheckpointStore {
        let layout = CBv2CompleteCheckpointManifest.historicalAttentionLayout
        let epoch = try SSDCacheEpochStore(root: modelRoot, binding: .init(modelId: modelID,
            modelAggregateHash: identity.modelAggregateHash, promptContractId: identity.promptContractID,
            blockHashVersion: CBv2BlockHasher.version, blockSize: PrefixCachePolicy.blockSize,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: layout), keyFingerprint: "page-key"))
        let store = SSDHybridCheckpointStore(config: .init(modelId: modelID, identity: identity,
            backendLayout: layout, root: modelRoot, dedicatedRoot: root, epochStore: epoch,
            maxReadBytes: 16 << 20, maxStageMillis: 10000, minEffectiveTokens: 1024, ttlSeconds: 3600,
            strictFsync: true, nowSeconds: { Int64(Date().timeIntervalSince1970) },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}), kekKey: key, kvBudget: budget,
            diskBudget: diskBudget, maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        return store
    }

    func source(position: Int, changed: Bool = false) throws -> CBv2CompleteCheckpointExport {
        let manifest = CBv2CompleteCheckpointManifest(identity: identity, position: position, chunkSize: 1024,
            prefixTokens: Array(tokens.prefix(position)), cacheSalt: "scope-a", assistantCodecID: nil,
            tensors: try codec.tensorDescriptors(position: position),
            backendLayout: CBv2CompleteCheckpointManifest.historicalAttentionLayout,
            attentionLayers: codec.historicalLayout?.layers)
        let arrays = manifest.tensors.enumerated().map { index, tensor in
            let first = position - tensor.shape[2]
            let values = (0..<(tensor.byteCount / 4)).map { offset -> Float in
                let head = offset / (tensor.shape[2] * 64)
                let absolute = first + offset / 64 % tensor.shape[2]
                return Float(index * 1_000_000 + head * 100_000 + absolute * 3 + offset % 64 + (changed ? 1 : 0))
            }
            return MLXArray(values).reshaped(tensor.shape)
        }
        eval(arrays)
        return .init(manifest: manifest, arrays: arrays)
    }
    func request() -> CBv2Request {
        var request = CBv2Request(id: .init(50), promptTokens: tokens, maxTokens: 8)
        request.cacheSalt = "scope-a"
        return request
    }
    func reserveScratch() throws -> CBv2CompleteCheckpointIOLease {
        .init(reservation: try codec.admission.reserveTransient(bytes: CBv2CompleteCheckpointManifest.maximumProviderScratchBytes))
    }
    func donate(_ store: SSDHybridCheckpointStore, position: Int, receipt: UInt64 = 88, changed: Bool = false) async throws -> [Int] {
        let source = try source(position: position, changed: changed)
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(receipt), tokens: tokens, cacheSalt: "scope-a") {
                continuation.resume(returning: $0)
            }
        }
    }
    func tag(_ store: SSDHybridCheckpointStore, position: Int) -> Data {
        store.lookupKeys.checkpointTag(chainHash: store.hashes(tokens: tokens, scope: "scope-a")[position / 256 - 1], cacheSalt: "scope-a")
    }
    func file(_ store: SSDHybridCheckpointStore, position: Int) -> URL {
        SSDBlockStore.fileURL(root: modelRoot, tag16Hex: Data(tag(store, position: position).prefix(16)).hexString)
    }
    func envelope(_ store: SSDHybridCheckpointStore, position: Int) throws -> SSDSharedCheckpointPages.Envelope {
        let decoded = try SSDBlockStore.read(from: file(store, position: position), kekKey: key)
        return try .decode(try #require(decoded.1.first))
    }
    func verify(_ store: SSDHybridCheckpointStore, position: Int, changed: Bool = false) throws {
        let envelope = try envelope(store, position: position)
        let expected = try source(position: position, changed: changed)
        defer { expected.close() }
        try SSDSharedCheckpointPages.read(envelope: envelope, encoded: envelope.encoded(),
            checkpoint: file(store, position: position), tag: tag(store, position: position), key: key,
            maximumPlaintextBytes: 16 << 20, check: {}, countRead: { _ in }, consume: { page, data in
                let original = try expected.readSegment(tensorIndex: page.tensor, byteOffset: page.offset, maximumBytes: page.bytes)
                #expect(data == original)
            })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
