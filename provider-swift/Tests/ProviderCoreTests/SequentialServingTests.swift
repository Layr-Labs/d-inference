// Copyright © 2026 Eigen Labs.
//
// Sequential-serving route for models whose cache layout the batched engine
// cannot represent (DeepSeek-V4). Covers the pure admission gate and the
// batching-support classifier the load snapshot consumes.

import MLXLMCommon
import XCTest

@testable import MLXLLM
@testable import ProviderCore

final class SequentialServingTests: XCTestCase {

    // MARK: - Pure admission gate

    func testSequentialAdmissionRequiresFullExclusivity() {
        XCTAssertTrue(BatchScheduler.sequentialAdmissionAllowed(
            activeBridgeCount: 0, fastPathTaskCount: 0, fastPathAdmitting: false))
        XCTAssertFalse(BatchScheduler.sequentialAdmissionAllowed(
            activeBridgeCount: 1, fastPathTaskCount: 0, fastPathAdmitting: false),
            "an in-flight request must reject the next one (retryable)")
        XCTAssertFalse(BatchScheduler.sequentialAdmissionAllowed(
            activeBridgeCount: 0, fastPathTaskCount: 1, fastPathAdmitting: false),
            "a running single-sequence task must block admission")
        XCTAssertFalse(BatchScheduler.sequentialAdmissionAllowed(
            activeBridgeCount: 0, fastPathTaskCount: 0, fastPathAdmitting: true),
            "the admission fence must block until the previous submit resolves")
    }

    // MARK: - Batching-support classifier (drives requiresSequentialServing)

    func testDeepseekV4CacheLayoutClassifiesAsSequential() {
        let layout: [any KVCache] = [
            RotatingKVCache(maxSize: 128),
            DeepseekV4LayerCache(
                rotating: RotatingKVCache(maxSize: 128),
                pooling: [PoolingCache(ratio: 4), PoolingCache(ratio: 4)]),
            DeepseekV4LayerCache(
                rotating: RotatingKVCache(maxSize: 128),
                pooling: [PoolingCache(ratio: 128)]),
        ]
        XCTAssertFalse(
            Scheduler.supportsBatchedServing(cacheLayout: layout),
            "DeepSeek-V4 layer caches must route to sequential serving — the "
                + "batched factory would silently substitute BatchKVCache")
    }

    func testStandardLayoutsRemainBatched() {
        XCTAssertTrue(Scheduler.supportsBatchedServing(cacheLayout: [
            KVCacheSimple(), KVCacheSimple(),
        ]), "pure-attention models stay on the batched engine")
        XCTAssertTrue(Scheduler.supportsBatchedServing(cacheLayout: [
            RotatingKVCache(maxSize: 512), KVCacheSimple(),
        ]), "hybrid sliding-window models (Gemma-4/GPT-OSS shape) stay batched")
        XCTAssertTrue(Scheduler.supportsBatchedServing(cacheLayout: []),
            "empty layout is trivially batched")
    }
}
