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
