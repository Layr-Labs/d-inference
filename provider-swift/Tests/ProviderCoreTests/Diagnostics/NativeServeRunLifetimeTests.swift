import Foundation
import Testing
@testable import ProviderCore

@Suite("Native serving qualification completion")
struct NativeServeRunLifetimeTests {
    @Test func prematureServeReturnFailsEvenWhenObserverReturnsNormallyOnCancellation() async throws {
        let observing = QualificationSignal()
        let cancelled = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: { await observing.wait() }, observe: {
                await observing.signal()
                do { try await Task.sleep(for: .seconds(60)) }
                catch is CancellationError { await cancelled.signal() }
            }, shutdown: { Issue.record("unobserved run started shutdown") })
        }
        await #expect(throws: NativeServeRunLifetime.Failure.servingEndedBeforeObservation) {
            try await result.value
        }
        await cancelled.wait()
    }

    @Test func observedShutdownCanFinishServeBeforeItsAcknowledgement() async throws {
        let serving = QualificationSignal()
        let stop = QualificationSignal()
        let served = QualificationSignal()
        try await NativeServeRunLifetime.run(serve: {
            await serving.signal()
            await stop.wait()
            await served.signal()
        }, observe: {
            await serving.wait()
        }, shutdown: {
            await stop.signal()
            await served.wait()
            #expect(!Task.isCancelled)
        })
    }

    @Test func observedShutdownStillWaitsForServingCompletion() async throws {
        let serving = QualificationSignal()
        let shutDown = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: {
                await serving.signal()
                await shutDown.wait()
                #expect(!Task.isCancelled)
            }, observe: {
                await serving.wait()
            }, shutdown: {
                await shutDown.signal()
            })
        }
        try await result.value
    }

    @Test func failedObserverDoesNotWaitForUncancellableServe() async throws {
        let serving = QualificationSignal()
        let release = QualificationSignal()
        let exited = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: {
                await serving.signal()
                await release.wait()
                await exited.signal()
            }, observe: {
                await serving.wait()
                throw QualificationFailure.observation
            }, shutdown: { Issue.record("failed observation started shutdown") })
        }
        await #expect(throws: QualificationFailure.observation) { try await result.value }
        // Failure must reach the CLI before an uncancellable native owner retires.
        await release.signal()
        await exited.wait()
    }

    @Test func servingErrorDoesNotWaitForUncancellableObserver() async throws {
        let observing = QualificationSignal()
        let release = QualificationSignal()
        let exited = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: {
                await observing.wait()
                throw QualificationFailure.serving
            }, observe: {
                await observing.signal()
                await release.wait()
                await exited.signal()
            }, shutdown: { Issue.record("cancelled observation started shutdown") })
        }
        await #expect(throws: QualificationFailure.serving) { try await result.value }
        await release.signal()
        await exited.wait()
    }

    @Test func servingErrorDuringShutdownDoesNotWaitForUncancellableDrain() async throws {
        let draining = QualificationSignal()
        let release = QualificationSignal()
        let exited = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: {
                await draining.wait()
                throw QualificationFailure.serving
            }, observe: {}, shutdown: {
                await draining.signal()
                await release.wait()
                await exited.signal()
            })
        }
        await #expect(throws: QualificationFailure.serving) { try await result.value }
        await release.signal()
        await exited.wait()
    }

    @Test(arguments: [QualificationShutdownOutcome.failed, .cancelled, .returnedAfterCancellation])
    func shutdownFailureDoesNotBecomeSuccess(outcome: QualificationShutdownOutcome) async throws {
        let serving = QualificationSignal()
        let stop = QualificationSignal()
        let served = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: {
                await serving.signal()
                await stop.wait()
                await served.signal()
            }, observe: {
                await serving.wait()
            }, shutdown: {
                await stop.signal()
                await served.wait()
                switch outcome {
                case .failed: throw QualificationFailure.shutdown
                case .cancelled: throw CancellationError()
                case .returnedAfterCancellation: withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        if outcome == .failed {
            await #expect(throws: QualificationFailure.shutdown) { try await result.value }
        } else {
            await #expect(throws: CancellationError.self) { try await result.value }
        }
    }

    @Test func callerCancellationCannotQualifyAnObserverThatSwallowsCancellation() async throws {
        let serving = QualificationSignal()
        let observing = QualificationSignal()
        let release = QualificationSignal()
        let exited = QualificationSignal()
        let observerExited = QualificationSignal()
        let result = Task {
            try await NativeServeRunLifetime.run(serve: {
                await serving.signal()
                await release.wait()
                await exited.signal()
            }, observe: {
                await serving.wait()
                await observing.signal()
                do { try await Task.sleep(for: .seconds(60)) }
                catch is CancellationError { await observerExited.signal() }
            }, shutdown: { Issue.record("cancelled run started shutdown") })
        }
        await observing.wait()
        result.cancel()
        await #expect(throws: CancellationError.self) { try await result.value }
        await release.signal()
        await exited.wait()
        await observerExited.wait()
    }
}

private enum QualificationFailure: Error { case observation, serving, shutdown }
enum QualificationShutdownOutcome { case failed, cancelled, returnedAfterCancellation }

private actor QualificationSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
