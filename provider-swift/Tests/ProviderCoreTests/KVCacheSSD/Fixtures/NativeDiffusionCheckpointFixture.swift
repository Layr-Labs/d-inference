import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

private struct NativeCheckpointTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [2] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [2] }
}

final class NativeDiffusionCheckpointFixture: @unchecked Sendable {
    let root: URL
    let modelRoot: URL
    let key = SymmetricKey(size: .bits256)
    let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: String(repeating: "a", count: 64),
        promptContractID: String(repeating: "b", count: 64), buildID: String(repeating: "c", count: 64),
        numericsFingerprint: String(repeating: "d", count: 64))
    let tokens = Array(repeating: [2, 3, 5, 7], count: 128).flatMap { $0 }
    let model: DiffusionGemmaTextDecoder
    let scalars: DiffusionGemmaEncoderTextParameters
    let codec: DiffusionGemmaPersistentPrefixCodec
    let engine: CBv2NativeBlockEngine
    let budget: GlobalKVCacheBudget

    init() throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let config = try JSONDecoder().decode(DiffusionGemmaTextConfiguration.self, from: Data(#"""
        {"model_type":"diffusion_gemma_text","vocab_size":128,"hidden_size":32,"intermediate_size":48,
         "moe_intermediate_size":16,"num_hidden_layers":2,"num_attention_heads":2,"num_key_value_heads":1,
         "num_global_key_value_heads":1,"head_dim":8,"global_head_dim":16,"num_experts":4,"top_k_experts":2,
         "sliding_window":8,"max_position_embeddings":4096,"layer_types":["sliding_attention","full_attention"],
         "rms_norm_eps":0.000001,"final_logit_softcapping":30,"use_bidirectional_attention":"vision",
         "tie_word_embeddings":true,"hidden_activation":"gelu_pytorch_tanh","attention_bias":false,
         "attention_dropout":0,"bos_token_id":2,"pad_token_id":0,"eos_token_id":1}
        """#.utf8))
        model = DiffusionGemmaTextDecoder(config)
        scalars = DiffusionGemmaEncoderTextParameters(layerCount: config.layerCount)
        engine = try .init(tokenizer: NativeCheckpointTokenizer(), kvBytesCapacity: 256 << 20,
            reservationForRequest: { _ in 1 << 20 },
            makeSession: { _, _ in throw CBv2NativeBlockError.unsupportedRequest("transfer fixture") })
        codec = try model.makePersistentPrefixCodec(verifiedIdentity: identity, kvDType: .float32)
        budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0, memorySnapshot: {
            let usage = Memory.snapshot()
            return .init(total: 64 << 30, active: UInt64(usage.activeMemory), cache: UInt64(usage.cacheMemory), systemAvailable: 64 << 30)
        })
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("native-complete-store-" + UUID().uuidString)
        modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
    }

    func prefixIdentity(scope: String = "tenant-a") throws -> DiffusionGemmaPrefixIdentity {
        try .init(tenantScope: scope, artifact: identity.modelAggregateHash, template: identity.promptContractID,
            media: "text-only", numericalProfile: identity.numericsFingerprint, epoch: "fixture")
    }
    func makeStore(useGlobalBudget: Bool = true) throws -> SSDHybridCheckpointStore {
        let epoch = try SSDCacheEpochStore(root: modelRoot, binding: .init(modelId: "native-fixture",
            modelAggregateHash: identity.modelAggregateHash, promptContractId: identity.promptContractID,
            blockHashVersion: CBv2BlockHasher.version, blockSize: PrefixCachePolicy.blockSize,
            layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(identity: identity, backendLayout: CBv2CompleteCheckpointManifest.diffusionBlockLayout),
            keyFingerprint: "fixture-key"))
        let store = SSDHybridCheckpointStore(config: .init(modelId: "native-fixture", identity: identity,
            backendLayout: CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            nativePrefillChunkSize: 256, root: modelRoot, dedicatedRoot: root,
            epochStore: epoch, maxReadBytes: 16 << 20, maxStageMillis: 1000, minEffectiveTokens: 256,
            ttlSeconds: 3600, strictFsync: false, nowSeconds: { Int64(Date().timeIntervalSince1970) },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}), kekKey: key, kvBudget: useGlobalBudget ? budget : nil,
            diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        return store
    }
    func request(scope: String = "tenant-a", appended: Bool = false) -> CBv2Request {
        .init(id: .init(1), promptTokens: tokens + (appended ? [11, 13] : []), maxTokens: 8, cacheSalt: scope)
    }
    func plan(_ manifest: CBv2CompleteCheckpointManifest, request: CBv2Request) throws -> CBv2NativeBlockCheckpointImportPlan {
        try codec.importPlan(manifest, prefixIdentity: prefixIdentity(scope: request.cacheSalt!),
            promptTokens: request.promptTokens, chunkSize: 256, maximumNewTokens: request.maxTokens, engine: engine)
    }
    func coldCache() throws -> DiffusionGemmaRequestCache {
        let cache = try DiffusionGemmaRequestCache(configuration: model.configuration, expectedPromptLength: 520)
        try MLX.withError { errors in
            for start in stride(from: 0, to: tokens.count, by: 256) {
                _ = try model.encode(tokenIds: MLXArray(Array(tokens[start..<start + 256])).asType(.int32).reshaped(1, 256), cache: cache, encoderParameters: scalars)
                try errors.check(); eval(cache.stateArrays()); try errors.check()
            }
        }
        return cache
    }
    func donate(_ store: SSDHybridCheckpointStore) async throws -> [Int] {
        let cache = try coldCache()
        let bytes = try cache.stateArrays().reduce(20 << 20) { try $0 + Memory.allocationFootprintUpperBound(byteCount: $1.nbytes) + 4096 }
        let permit = try engine.reserveNativeCheckpoint(bytes: bytes)
        defer { permit.close() }
        let checkpoint = try model.checkpoint(cache: cache, identity: prefixIdentity(), compact: true)
        let source = try codec.export(checkpoint, chunkSize: 256, engine: engine)
        return await withCheckedContinuation { continuation in
            store.donate(source, requestID: .init(10), tokens: tokens, cacheSalt: "tenant-a") { continuation.resume(returning: $0) }
        }
    }
    func file(_ store: SSDHybridCheckpointStore) throws -> URL {
        let hash = try #require(store.hashes(tokens: tokens, scope: "tenant-a").last)
        let tag = store.lookupKeys.checkpointTag(chainHash: hash, cacheSalt: "tenant-a")
        return SSDBlockStore.fileURL(root: modelRoot, tag16Hex: Data(tag.prefix(16)).hexString)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
