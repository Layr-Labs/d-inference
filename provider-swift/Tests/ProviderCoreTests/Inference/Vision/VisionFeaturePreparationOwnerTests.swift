import Foundation
import Testing
@testable import ProviderCore

private actor PreparationGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class PreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func record() { lock.withLock { value = true } }
    var observed: Bool { lock.withLock { value } }
}

@Test func featurePreparationCloseCancelsBeforeDrainAndRetainsSuspendedOwner() async throws {
    let owner = VisionFeaturePreparationOwner(limit: 1)
    let gate = PreparationGate()
    let cancellation = PreparationCancellation()
    let started = AsyncStream<Void>.makeStream()
    let task = Task {
        try await owner.perform {
            try await withTaskCancellationHandler {
                started.continuation.yield(())
                await gate.wait() // Model-container suspension need not observe cancellation.
                try Task.checkCancellation()
                return 7
            } onCancel: { cancellation.record() }
        }
    }
    for await _ in started.stream { break }
    let declined = try await owner.perform {
        Issue.record("A saturated optional cache owner must not execute another producer")
        return 9
    }
    #expect(declined == nil)
    owner.close()
    #expect(cancellation.observed)
    #expect(!owner.isDrained)
    await gate.open()
    do {
        _ = try await task.value
        Issue.record("Closed preparation must propagate cancellation")
    } catch is CancellationError {
        // The task really completed before the owner can retire.
    }
    await owner.drain()
    #expect(owner.isDrained)
    do {
        _ = try await owner.perform { 10 }
        Issue.record("A closed owner must reject future producers")
    } catch is CancellationError {}
}

@Test func featurePreparationCallerCancellationReachesOwnedTask() async throws {
    let owner = VisionFeaturePreparationOwner()
    let gate = PreparationGate()
    let cancellation = PreparationCancellation()
    let started = AsyncStream<Void>.makeStream()
    let task = Task {
        try await owner.perform {
            try await withTaskCancellationHandler {
                started.continuation.yield(())
                await gate.wait()
                try Task.checkCancellation()
                return 1
            } onCancel: { cancellation.record() }
        }
    }
    for await _ in started.stream { break }
    task.cancel()
    #expect(cancellation.observed)
    await gate.open()
    do {
        _ = try await task.value
        Issue.record("Caller cancellation must propagate")
    } catch is CancellationError {}
    owner.close()
    await owner.drain()
    #expect(owner.isDrained)
}
