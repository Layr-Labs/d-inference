import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
@testable import ProviderCore

final class SSDHybridCheckpointTestFixture: @unchecked Sendable {
    let root: URL
    let modelRoot: URL
    let key = SymmetricKey(size: .bits256)
    let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "fixture-weights", promptContractID: "fixture-template", buildID: "fixture-build", numericsFingerprint: "fixture-numerics")
    let tokens = (0..<513).map { $0 % 31 }
    let codec: CBv2CompleteCheckpointCodec
    let budget: GlobalKVCacheBudget
    let backend: PagedKVBackend?
    let sharedPaged: Bool
    var backendLayout: String {
        backend != nil ? CBv2CompleteCheckpointManifest.pagedLayout : CBv2CompleteCheckpointManifest.layout
    }

    init(sharedPaged: Bool = false, paged: Bool = false, budget: GlobalKVCacheBudget? = nil) throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        self.sharedPaged = sharedPaged
        let usesPaged = sharedPaged || paged
        self.budget = budget ?? GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: {
            let usage = Memory.snapshot()
            return .init(total: 64 << 30, active: UInt64(usage.activeMemory),
                         cache: UInt64(usage.cacheMemory), systemAvailable: 64 << 30)
        })
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("complete-store-\(UUID().uuidString)")
        modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        let kinds = [CBv2LayerKind(attention: .full, headDim: usesPaged ? 64 : 2,
                                  kvHeads: 1, queryHeads: 1, modelLayerIndex: 0)]
        let spec = CBv2RecurrentStateSpec(layers: [.init(
            modelLayerIndex: 1, convShape: [1, 2, 2], convDType: .float32,
            ssmShape: [1, 2, 2, 2], ssmDType: .float32)])
        let pagedConfig = usesPaged ? PagedKVPoolConfig(
            capacityBytes: 128 << 20, dtype: .float32, maxPrefillChunk: 256,
            segmentSizeBytes: 64 << 10, layerDTypes: [.float32]) : nil
        let residency: any CBv2KVResidencyPolicy
        if let pagedConfig { residency = CBv2PagedKVResidency(config: pagedConfig) }
        else { residency = CBv2ContiguousKVResidency() }
        let admission = AdmissionV2(
            layerKinds: kinds, bytesCapacity: 128 << 20,
            config: .init(watermarkFraction: 0, elementBytes: 4,
                          fixedBytesPerRequest: try spec.fixedBytesPerRequest()),
            residency: residency,
            processMemoryOwner: sharedPaged ? self.budget.makeEngineMemoryOwner() : nil)
        if let pagedConfig {
            let backend = try PagedKVBackend(layerKinds: kinds, config: pagedConfig)
            backend.pool.bindAdmission(admission)
            self.backend = backend
        } else {
            backend = nil
        }
        codec = CBv2CompleteCheckpointCodec(identity: identity, layerKinds: kinds,
            recurrentSpec: spec,
            kvDTypes: [.float32], assistant: nil,
            admission: admission, pagedConfig: pagedConfig)
    }

    func makeStore(readCap: Int = 16 << 20, epoch: Bool = true, useGlobalBudget: Bool = true, diskBudget: SSDDiskBudget = SSDDiskBudget(),
                   maxWriteBytesPerDay: Int = 1 << 30,
                   donationRecorder: any PrefixCacheDonationRecording = PrefixCacheDonationTelemetry.shared) throws -> SSDHybridCheckpointStore {
        let epochStore: SSDCacheEpochStore? = epoch ? try .init(root: modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: identity.modelAggregateHash,
            promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: identity, backendLayout: backendLayout),
            keyFingerprint: "fixture-key")) : nil
        let store = SSDHybridCheckpointStore(config: .init(modelId: "fixture-model", identity: identity,
            backendLayout: backendLayout,
            root: modelRoot, dedicatedRoot: root, epochStore: epochStore, maxReadBytes: readCap,
            maxStageMillis: 1000, minEffectiveTokens: 256, ttlSeconds: 3600, strictFsync: false,
            nowSeconds: { Int64(Date().timeIntervalSince1970) }, diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: key, kvBudget: useGlobalBudget ? budget : nil, diskBudget: diskBudget, maxWriteBytesPerDay: maxWriteBytesPerDay, donationRecorder: donationRecorder)
        store.scanOnDisk()
        return store
    }

    func manifest(position: Int = 256, scope: String = "tenant-a") throws -> CBv2CompleteCheckpointManifest {
        .init(identity: identity, position: position, chunkSize: 256, prefixTokens: Array(tokens.prefix(position)),
              cacheSalt: scope, assistantCodecID: nil, tensors: try codec.tensorDescriptors(position: position),
              backendLayout: backendLayout)
    }

    func source(position: Int = 256, scope: String = "tenant-a") throws -> CBv2CompleteCheckpointExport {
        let manifest = try manifest(position: position, scope: scope)
        let arrays = manifest.tensors.enumerated().map { index, tensor in
            MLXArray(Array(repeating: Float(index + 1), count: tensor.byteCount / 4)).reshaped(tensor.shape)
        }
        eval(arrays)
        return .init(manifest: manifest, arrays: arrays, usesProcessMemoryOwner: sharedPaged)
    }

    func request(scope: String = "tenant-a") -> CBv2Request {
        var request = CBv2Request(id: .init(7), promptTokens: tokens, maxTokens: 8)
        request.cacheSalt = scope
        return request
    }

    func reserveReadScratch() throws -> CBv2CompleteCheckpointIOLease {
        if sharedPaged { return .init(reservation: .init(onRelease: {}), usesProcessMemoryOwner: true) }
        return .init(reservation: try codec.admission.reserveTransient(
            bytes: CBv2CompleteCheckpointManifest.maximumProviderScratchBytes))
    }

    func plan(_ manifest: CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan {
        try codec.plan(manifest: manifest, request: request(), minimumChunkSize: 256, maximumChunkSize: 256)
    }

    func donate(_ store: SSDHybridCheckpointStore, receipt: UInt64 = 10, position: Int = 256) async throws -> [Int] {
        let source = try source(position: position)
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(receipt), tokens: tokens, cacheSalt: "tenant-a") { continuation.resume(returning: $0) }
        }
    }

    func file(_ store: SSDHybridCheckpointStore, position: Int = 256) -> URL {
        let chain = store.hashes(tokens: tokens, scope: "tenant-a")
        let tag = store.lookupKeys.checkpointTag(chainHash: chain[position / 256 - 1], cacheSalt: "tenant-a")
        return SSDBlockStore.fileURL(root: modelRoot, tag16Hex: Data(tag.prefix(16)).hexString)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
