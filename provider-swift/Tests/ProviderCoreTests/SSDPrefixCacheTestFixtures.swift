// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Shared fixtures

let fixtureBlockSize = 8
let fixtureKVHeads = 2
let fixtureHeadDim = 8

/// Layer kinds: layer 0 full-attention (cacheable), layer 1 sliding-window
/// (never cached; adoption bound handled via the explicit config value).
let fixtureLayerKinds: [CBv2LayerKind] = [
    CBv2LayerKind(attention: .full, headDim: fixtureHeadDim, kvHeads: fixtureKVHeads, queryHeads: 4),
    CBv2LayerKind(
        attention: .slidingWindow(4), headDim: fixtureHeadDim, kvHeads: fixtureKVHeads,
        queryHeads: 4),
]

func tempDir(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("ssd-prefix-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Deterministic donation snapshot covering `tokenCount` tokens: layer 0
/// carries [1, kvHeads, tokenCount, headDim] f16 arrays whose values are a
/// function of position, layer 1 is nil (windowed).
func fixtureSnapshots(tokenCount: Int, seed: Float = 1.0)
    -> [(keys: MLXArray, values: MLXArray, offset: Int)?]
{
    // MLX kernels need the metallib colocated with the xctest bundle
    // (same helper every MLX-touching suite uses).
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    let shape = [1, fixtureKVHeads, tokenCount, fixtureHeadDim]
    let count = shape.reduce(1, *)
    let base = MLXArray(0 ..< count).reshaped(shape).asType(.float16)
    let keys = (base * seed).asType(.float16)
    let values = (base * (seed + 0.5)).asType(.float16)
    eval(keys, values)
    return [(keys: keys, values: values, offset: tokenCount), nil]
}

func donateFixture(
    _ cache: SSDPrefixCache, tokens: [Int], salt: String? = nil, seed: Float = 1.0
) {
    cache.donate(
        tokens: tokens,
        snapshots: fixtureSnapshots(tokenCount: tokens.count, seed: seed),
        layerKinds: fixtureLayerKinds,
        cacheSalt: salt)
}

func blockMetadataFixture(sizes: [Int]) -> SSDBlockMetadata {
    SSDBlockMetadata(
        lookupTag: String(repeating: "ab", count: 32),
        weightHash: "w-hash",
        layoutEpoch: "cbv2-frozen-full-3|native-fp|8|deadbeef",
        blockSize: 8,
        layerCount: 2,
        chunks: sizes.enumerated().map { index, _ in
            SSDBlockChunkDescriptor(
                layerIndex: 0, tensor: index % 2, shape: [1, 2, 8, 8], dtype: "float16")
        },
        chunkPlaintextSizes: sizes,
        createdAt: 1000)
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64
    init(_ now: Int64) { self._now = now }
    var now: Int64 { lock.withLock { _now } }
    func advance(_ seconds: Int64) { lock.withLock { _now += seconds } }
}

func makeCache(
    dir: URL,
    kek: SymmetricKey,
    clock: ClockBox,
    blockSize: Int = fixtureBlockSize,
    ttlSeconds: Int64 = 900,
    adoptionBound: Int = 0,
    minEffectiveTokens: Int = fixtureBlockSize,
    maxStageBytes: Int = 1 << 30,
    maxWriteBytesPerDay: Int = 0,
    diskBudgetBytes: Int = 1 << 40,
    kvBudget: GlobalKVCacheBudget? = nil,
    diskBudget: SSDDiskBudget = SSDDiskBudget(),
    epochStore: SSDCacheEpochStore? = nil,
    maintainWholeRoot: (@Sendable () -> Void)? = nil,
    donationRecorder: any PrefixCacheDonationRecording = PrefixCacheDonationTelemetry.shared
) -> SSDPrefixCache {
    let config = SSDPrefixCache.Config(
        modelId: "test-model",
        promptContractID: "test-prompt-contract",
        weightHash: "test-weight-hash",
        blockSize: blockSize,
        adoptionBoundTokens: adoptionBound,
        layoutEpoch: SSDBlockStore.layoutEpoch(
            blockSize: blockSize, layerKinds: fixtureLayerKinds),
        epochStore: epochStore,
        root: dir,
        ttlSeconds: ttlSeconds,
        minEffectiveTokens: minEffectiveTokens,
        maxStageBytes: maxStageBytes,
        maxStageMillis: 1_000_000,
        nowSeconds: { clock.now })
    return SSDPrefixCache(
        config: config, kekKey: kek, kvBudget: kvBudget, diskBudget: diskBudget,
        maxWriteBytesPerDay: maxWriteBytesPerDay, strictFsync: false,
        diskBudgetBytes: { diskBudgetBytes },
        maintainWholeRoot: maintainWholeRoot,
        donationRecorder: donationRecorder)
}

/// Poll until the cache's index holds `count` entries (write-behind is
/// asynchronous by design).
func waitForIndexCount(
    _ cache: SSDPrefixCache, atLeast count: Int, timeout: Duration = .seconds(20)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if cache.index.count >= count { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return cache.index.count >= count
}

func dbk3Files(under root: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "dbk3" }
}

func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTime
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: semaphore.wait(timeout: timeout))
        }
    }
}
