import Foundation
import Testing
@testable import ProviderCore

@Test func plannerRejectsInvalidDuplicateAndOverBudgetRequests() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 1,
            maxActiveTokenBudget: 10,
            maxTokensPerBatch: 6
        )
    )

    #expect(
        await planner.admit(id: "zero", promptTokenCount: 0, maxOutputTokens: 1)
            == .rejected(requestID: "zero", reason: .invalidTokenCount)
    )
    #expect(
        await planner.admit(id: "too-large", promptTokenCount: 6, maxOutputTokens: 5)
            == .rejected(requestID: "too-large", reason: .requestExceedsActiveTokenBudget)
    )
    #expect(
        await planner.admit(id: "prefill-too-large", promptTokenCount: 7, maxOutputTokens: 1)
            == .rejected(requestID: "prefill-too-large", reason: .requestExceedsBatchTokenBudget)
    )

    #expect(
        await planner.admit(id: "a", promptTokenCount: 4, maxOutputTokens: 4)
            == .queued(requestID: "a", position: 1)
    )
    #expect(
        await planner.admit(id: "a", promptTokenCount: 4, maxOutputTokens: 4)
            == .rejected(requestID: "a", reason: .duplicateRequestID)
    )
    #expect(
        await planner.admit(id: "b", promptTokenCount: 1, maxOutputTokens: 1)
            == .rejected(requestID: "b", reason: .queueFull)
    )
}

@Test func plannerBuildsDeterministicContinuousBatches() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 3,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 100,
            maxTokensPerBatch: 20
        )
    )

    await planner.admit(id: "a", promptTokenCount: 4, maxOutputTokens: 4)
    await planner.admit(id: "b", promptTokenCount: 3, maxOutputTokens: 4)
    await planner.admit(id: "c", promptTokenCount: 2, maxOutputTokens: 4)

    let first = await planner.nextBatch()
    #expect(first?.sequence == 1)
    #expect(first?.prefill?.id == "a")
    #expect(first?.decodes.isEmpty == true)
    #expect(first?.tokenCost == 4)

    #expect(await planner.markPrefillComplete(requestID: "a"))

    let second = await planner.nextBatch()
    #expect(second?.sequence == 2)
    #expect(second?.decodes.map(\.id) == ["a"])
    #expect(second?.prefill?.id == "b")
    #expect(second?.orderedRequests.map(\.id) == ["a", "b"])
    #expect(second?.tokenCost == 4)

    #expect(await planner.recordDecodeStep(requestID: "a") == .generated(remainingTokens: 3))
    #expect(await planner.markPrefillComplete(requestID: "b"))

    let third = await planner.nextBatch()
    #expect(third?.sequence == 3)
    #expect(third?.decodes.map(\.id) == ["a", "b"])
    #expect(third?.prefill?.id == "c")
    #expect(third?.decodes.first?.generatedTokenCount == 1)
    #expect(third?.tokenCost == 4)
}

@Test func plannerCancellationRemovesPendingAndActiveRequests() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 1,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 100,
            maxTokensPerBatch: 20
        )
    )

    await planner.admit(id: "a", promptTokenCount: 4, maxOutputTokens: 4)
    await planner.admit(id: "b", promptTokenCount: 4, maxOutputTokens: 4)

    let first = await planner.nextBatch()
    #expect(first?.prefill?.id == "a")

    var snapshot = await planner.snapshot()
    #expect(snapshot.activeRequestIDs == ["a"])
    #expect(snapshot.pendingRequestIDs == ["b"])

    #expect(await planner.cancel(requestID: "b"))
    snapshot = await planner.snapshot()
    #expect(snapshot.pendingRequestIDs.isEmpty)
    #expect(snapshot.activeRequestIDs == ["a"])

    #expect(await planner.cancel(requestID: "a"))
    snapshot = await planner.snapshot()
    #expect(snapshot.pendingRequestIDs.isEmpty)
    #expect(snapshot.activeRequestIDs.isEmpty)

    #expect(await planner.cancel(requestID: "missing") == false)
    #expect(
        await planner.admit(id: "c", promptTokenCount: 2, maxOutputTokens: 2)
            == .queued(requestID: "c", position: 1)
    )
    #expect(await planner.nextBatch()?.prefill?.id == "c")
}

@Test func plannerDelaysPrefillUntilTokenBudgetIsAvailable() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 10,
            maxTokensPerBatch: 20
        )
    )

    await planner.admit(id: "a", promptTokenCount: 5, maxOutputTokens: 3)
    await planner.admit(id: "b", promptTokenCount: 5, maxOutputTokens: 3)

    #expect(await planner.nextBatch()?.prefill?.id == "a")
    #expect(await planner.markPrefillComplete(requestID: "a"))

    let blocked = await planner.nextBatch()
    #expect(blocked?.decodes.map(\.id) == ["a"])
    #expect(blocked?.prefill == nil)

    #expect(await planner.complete(requestID: "a"))
    let admittedAfterCompletion = await planner.nextBatch()
    #expect(admittedAfterCompletion?.prefill?.id == "b")
    #expect(admittedAfterCompletion?.decodes.isEmpty == true)
}

@Test func plannerBatchTokenBudgetDefersLargePrefillsBehindDecodeSteps() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 100,
            maxTokensPerBatch: 5
        )
    )

    await planner.admit(id: "decode-first", promptTokenCount: 1, maxOutputTokens: 2)
    await planner.admit(id: "large-prefill", promptTokenCount: 5, maxOutputTokens: 2)

    #expect(await planner.nextBatch()?.prefill?.id == "decode-first")
    #expect(await planner.markPrefillComplete(requestID: "decode-first"))

    let decodeOnly = await planner.nextBatch()
    #expect(decodeOnly?.decodes.map(\.id) == ["decode-first"])
    #expect(decodeOnly?.prefill == nil)

    #expect(await planner.complete(requestID: "decode-first"))
    let prefillAfterDecodeCompletes = await planner.nextBatch()
    #expect(prefillAfterDecodeCompletes?.prefill?.id == "large-prefill")
    #expect(prefillAfterDecodeCompletes?.tokenCost == 5)
}

// MARK: - Planner integration tests (exercise paths used by BatchScheduler)

/// Simulates the BatchScheduler admission flow: admit, then complete, verify
/// the planner releases budget so subsequent requests are admitted.
@Test func plannerAdmissionAndCompletionReleasesBudget() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 128,
            maxActiveTokenBudget: 20,
            maxTokensPerBatch: 4096
        )
    )

    // Admit a request that takes most of the budget.
    let result1 = await planner.admit(id: "req-1", promptTokenCount: 8, maxOutputTokens: 10)
    #expect(result1 == .queued(requestID: "req-1", position: 1))

    // Promote to active via nextBatch.
    let batch1 = await planner.nextBatch()
    #expect(batch1?.prefill?.id == "req-1")
    await planner.markPrefillComplete(requestID: "req-1")

    // Budget is 18/20 used. A second request of 8+10=18 would exceed budget.
    let result2 = await planner.admit(id: "req-2", promptTokenCount: 8, maxOutputTokens: 10)
    #expect(result2 == .queued(requestID: "req-2", position: 1))

    // req-2 is queued but nextBatch should NOT prefill it (budget exhausted).
    let batch2 = await planner.nextBatch()
    #expect(batch2?.prefill == nil)
    #expect(batch2?.decodes.map(\.id) == ["req-1"])

    // Complete req-1 -- budget should be freed.
    #expect(await planner.complete(requestID: "req-1"))

    let snapshot = await planner.snapshot()
    #expect(snapshot.activeTokenBudgetUsed == 0)
    #expect(snapshot.activeRequestIDs.isEmpty)
    #expect(snapshot.pendingRequestIDs == ["req-2"])

    // Now req-2 can be prefilled.
    let batch3 = await planner.nextBatch()
    #expect(batch3?.prefill?.id == "req-2")
}

/// Verifies that the planner rejects requests that exceed the active token
/// budget, matching the error path in BatchScheduler.submit().
@Test func plannerRejectsWhenActiveTokenBudgetExceeded() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 4,
            maxQueuedRequests: 128,
            maxActiveTokenBudget: 100,
            maxTokensPerBatch: 4096
        )
    )

    // A request whose reserved tokens (prompt + maxOutput) exceed the budget.
    let result = await planner.admit(id: "huge", promptTokenCount: 50, maxOutputTokens: 51)
    #expect(result == .rejected(requestID: "huge", reason: .requestExceedsActiveTokenBudget))
}

/// Verifies that the planner rejects requests whose prompt exceeds the
/// batch token budget, matching the error path in BatchScheduler.submit().
@Test func plannerRejectsWhenBatchTokenBudgetExceeded() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 4,
            maxQueuedRequests: 128,
            maxActiveTokenBudget: 100_000,
            maxTokensPerBatch: 4096
        )
    )

    // Prompt alone exceeds the per-batch token budget.
    let result = await planner.admit(id: "big-prompt", promptTokenCount: 4097, maxOutputTokens: 100)
    #expect(result == .rejected(requestID: "big-prompt", reason: .requestExceedsBatchTokenBudget))
}

/// Verifies that the planner rejects when the queue is full, matching the
/// error path in BatchScheduler.submit().
@Test func plannerRejectsWhenQueueFull() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 1,
            maxQueuedRequests: 2,
            maxActiveTokenBudget: 100_000,
            maxTokensPerBatch: 4096
        )
    )

    #expect(await planner.admit(id: "a", promptTokenCount: 10, maxOutputTokens: 10) == .queued(requestID: "a", position: 1))
    #expect(await planner.admit(id: "b", promptTokenCount: 10, maxOutputTokens: 10) == .queued(requestID: "b", position: 2))
    let result = await planner.admit(id: "c", promptTokenCount: 10, maxOutputTokens: 10)
    #expect(result == .rejected(requestID: "c", reason: .queueFull))
}

/// Verifies snapshot budget fields that BatchScheduler.backendCapacity() reads.
@Test func plannerSnapshotReflectsActiveAndQueuedBudgets() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 1000,
            maxTokensPerBatch: 200
        )
    )

    // Admit two requests.
    await planner.admit(id: "a", promptTokenCount: 30, maxOutputTokens: 70)
    await planner.admit(id: "b", promptTokenCount: 20, maxOutputTokens: 80)

    // Both are pending initially.
    var snapshot = await planner.snapshot()
    #expect(snapshot.activeTokenBudgetUsed == 0)
    #expect(snapshot.queuedTokenBudget == 200) // (30+70) + (20+80)
    #expect(snapshot.pendingRequests.count == 2)
    #expect(snapshot.activeRequests.count == 0)

    // Promote "a" to active.
    let batch = await planner.nextBatch()
    #expect(batch?.prefill?.id == "a")
    await planner.markPrefillComplete(requestID: "a")

    snapshot = await planner.snapshot()
    #expect(snapshot.activeTokenBudgetUsed == 100) // 30+70
    #expect(snapshot.queuedTokenBudget == 100) // 20+80 still pending
    #expect(snapshot.activeRequests.count == 1)
    #expect(snapshot.pendingRequests.count == 1)

    // Complete "a", promote "b".
    await planner.complete(requestID: "a")
    let batch2 = await planner.nextBatch()
    #expect(batch2?.prefill?.id == "b")
    await planner.markPrefillComplete(requestID: "b")

    snapshot = await planner.snapshot()
    #expect(snapshot.activeTokenBudgetUsed == 100) // 20+80
    #expect(snapshot.queuedTokenBudget == 0)
    #expect(snapshot.activeRequests.count == 1)
    #expect(snapshot.pendingRequests.count == 0)
}

/// Verifies that cancelling a request in the planner releases its budget,
/// matching the lifecycle tracking in BatchScheduler.finishRequest() and
/// BatchScheduler.cancel(requestId:).
@Test func plannerCancelReleasesTokenBudget() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 100,
            maxTokensPerBatch: 100
        )
    )

    await planner.admit(id: "a", promptTokenCount: 40, maxOutputTokens: 40)
    _ = await planner.nextBatch() // prefill "a"
    await planner.markPrefillComplete(requestID: "a")

    var snapshot = await planner.snapshot()
    #expect(snapshot.activeTokenBudgetUsed == 80)

    // Cancel "a" -- should release budget.
    #expect(await planner.cancel(requestID: "a"))
    snapshot = await planner.snapshot()
    #expect(snapshot.activeTokenBudgetUsed == 0)
    #expect(snapshot.activeRequests.isEmpty)
}

/// Verifies that the policy created by BatchScheduler.loadModel() uses
/// the expected defaults for queue depth and batch token budget.
@Test func schedulerPolicyDefaultsMatchExpectedValues() async {
    let policy = BatchSchedulingPolicy(
        maxConcurrentRequests: 4,
        maxQueuedRequests: 128,
        maxActiveTokenBudget: 8192,
        maxTokensPerBatch: 4096
    )

    #expect(policy.maxConcurrentRequests == 4)
    #expect(policy.maxQueuedRequests == 128)
    #expect(policy.maxActiveTokenBudget == 8192)
    #expect(policy.maxTokensPerBatch == 4096)
}

@Test func adaptiveCapDoesNotExpandBeforeEnoughSamples() {
    let policy = AdaptiveBatchCapPolicy(targetMinPerRequestTps: 15, expansionHeadroomMultiplier: 1.15)
    let cap = policy.nextCap(
        currentCap: 2,
        hardCap: 4,
        observedBatchSize: 2,
        performanceByBatchSize: [2: AdaptiveBatchPerformanceBucket(aggregateTps: 80, perRequestTps: 40, samples: 7)]
    )

    #expect(cap == 2)
}

@Test func adaptiveCapExpandsWithTpsHeadroom() {
    let policy = AdaptiveBatchCapPolicy(targetMinPerRequestTps: 15, expansionHeadroomMultiplier: 1.15)
    let cap = policy.nextCap(
        currentCap: 2,
        hardCap: 4,
        observedBatchSize: 2,
        performanceByBatchSize: [2: AdaptiveBatchPerformanceBucket(aggregateTps: 80, perRequestTps: 18, samples: 8)]
    )

    #expect(cap == 3)
}

@Test func adaptiveCapShrinksBelowTargetTps() {
    let policy = AdaptiveBatchCapPolicy(targetMinPerRequestTps: 15, expansionHeadroomMultiplier: 1.15)
    let cap = policy.nextCap(
        currentCap: 4,
        hardCap: 4,
        observedBatchSize: 4,
        performanceByBatchSize: [
            2: AdaptiveBatchPerformanceBucket(aggregateTps: 36, perRequestTps: 18, samples: 8),
            4: AdaptiveBatchPerformanceBucket(aggregateTps: 40, perRequestTps: 10, samples: 8),
        ]
    )

    #expect(cap == 2)
}

@Test func adaptiveCapDoesNotExpandWhenNextBucketHasBadSignal() {
    let policy = AdaptiveBatchCapPolicy(targetMinPerRequestTps: 15, expansionHeadroomMultiplier: 1.15)
    let cap = policy.nextCap(
        currentCap: 2,
        hardCap: 4,
        observedBatchSize: 2,
        performanceByBatchSize: [
            2: AdaptiveBatchPerformanceBucket(aggregateTps: 80, perRequestTps: 18, samples: 8),
            3: AdaptiveBatchPerformanceBucket(aggregateTps: 36, perRequestTps: 12, samples: 8),
        ]
    )

    #expect(cap == 2)
}

@Test func adaptiveBucketRecordKeepsEwmaAndSampleCount() {
    var bucket = AdaptiveBatchPerformanceBucket()

    bucket.record(aggregateTps: 40, perRequestTps: 20)
    bucket.record(aggregateTps: 20, perRequestTps: 10)

    #expect(bucket.samples == 2)
    #expect(bucket.aggregateTps == 35)
    #expect(bucket.perRequestTps == 17.5)
}

@Test func plannerQueuesFittingRequestEvenWhenActiveBudgetIsCurrentlyFull() async {
    let planner = BatchQueuePlanner(
        policy: BatchSchedulingPolicy(
            maxConcurrentRequests: 2,
            maxQueuedRequests: 10,
            maxActiveTokenBudget: 10,
            maxTokensPerBatch: 10
        )
    )

    #expect(await planner.admit(id: "active", promptTokenCount: 5, maxOutputTokens: 5) == .queued(requestID: "active", position: 1))
    #expect(await planner.nextBatch()?.prefill?.id == "active")
    #expect(await planner.markPrefillComplete(requestID: "active"))

    #expect(await planner.admit(id: "queued", promptTokenCount: 5, maxOutputTokens: 5) == .queued(requestID: "queued", position: 1))
    #expect(await planner.admit(id: "oversize", promptTokenCount: 6, maxOutputTokens: 5) == .rejected(requestID: "oversize", reason: .requestExceedsActiveTokenBudget))
}

@Test func schedulerUsesDefaultReservationWhenMaxTokensIsOmitted() {
    #expect(BatchScheduler.resolvedMaxTokens(requested: nil, defaultMaxTokens: 4096) == 4096)
    #expect(BatchScheduler.resolvedMaxTokens(requested: 128, defaultMaxTokens: 4096) == 128)
}

@Test func schedulerBoundsConfigJSONBeforeReading() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchSchedulerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let smallConfig = directory.appendingPathComponent("small-config.json")
    try Data(#"{"num_hidden_layers":1}"#.utf8).write(to: smallConfig)
    #expect(BatchScheduler.readBoundedConfigJSON(smallConfig) != nil)

    let largeConfig = directory.appendingPathComponent("large-config.json")
    let oversized = Data(repeating: UInt8(ascii: "{"), count: BatchScheduler.maxConfigJSONBytes + 1)
    try oversized.write(to: largeConfig)
    #expect(BatchScheduler.readBoundedConfigJSON(largeConfig) == nil)
}
