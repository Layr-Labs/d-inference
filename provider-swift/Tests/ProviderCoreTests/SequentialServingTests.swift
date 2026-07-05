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

    // MARK: - Runner dispatch (review P1-3: sequential requests must never
    // hit mlx-swift-lm's tool-aware text loop, tool-bearing or not)

    func testSequentialAlwaysUsesRawTextRunnerRegardlessOfTools() {
        // The dispatch decision does not take an `allowFastPath`/tools
        // parameter at all — sequential-serving models route EVERY request
        // (tool-bearing or plain text) through the raw-text loop, because a
        // false-positive tool-call parse is unsafe for both shapes (see
        // BatchScheduler+SequentialRawRunner.swift). This test documents that
        // by checking both "intents" resolve identically.
        let toolBearingIntent = BatchScheduler.fastPathRunnerKind(useSequential: true)
        let plainTextIntent = BatchScheduler.fastPathRunnerKind(useSequential: true)
        XCTAssertEqual(toolBearingIntent, .rawTextLoop,
            "sequential + tools must use the raw runner, never container.generate's tool parser")
        XCTAssertEqual(plainTextIntent, .rawTextLoop,
            "sequential + no tools must ALSO use the raw runner — a false-positive tool-call "
                + "parse on plain generated text is unsafe even without tools declared")
    }

    func testNonSequentialUsesToolAwareGenerateForTheGemmaFastPath() {
        XCTAssertEqual(
            BatchScheduler.fastPathRunnerKind(useSequential: false), .toolAwareGenerate,
            "the B=1 Gemma greedy fast path is the only caller of container.generate's "
                + "tool-aware loop, and only reaches it via its own allowFastPath gate")
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

    /// Sequential-serving models must advertise exactly one slot to the
    /// coordinator: the submit gate admits one request at a time, so a
    /// higher advertised concurrency would guarantee bounced dispatches.
    func testSequentialServingAdvertisesSingleSlot() async {
        let scheduler = BatchScheduler(maxConcurrentRequests: 4)
        await scheduler._setRequiresSequentialServingForTest(true)
        let capacity = await scheduler.capacity()
        XCTAssertEqual(
            capacity.maxConcurrent, 1,
            "sequential-serving models admit one request at a time; the heartbeat must say so")
        await scheduler._setRequiresSequentialServingForTest(false)
        let restored = await scheduler.capacity()
        XCTAssertGreaterThan(restored.maxConcurrent, 1, "batched models keep the real cap")
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
