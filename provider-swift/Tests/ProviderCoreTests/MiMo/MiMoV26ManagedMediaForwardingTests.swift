import Foundation
import XCTest
@testable import ProviderCore

/// Host event/lease fidelity tests. Injected stream events are NOT GPU-failure,
/// SDK-retirement, memory-reclamation or model-qualification evidence.
final class MiMoV26ManagedMediaForwardingTests: XCTestCase {
    private final class Witness: @unchecked Sendable {
        private let lock = NSLock()
        private var releases = 0
        private var cancellations = 0
        private var cancelledTask = false
        let released: XCTestExpectation
        init(_ released: XCTestExpectation) { self.released = released }
        func release(_ model: String) {
            lock.withLock { releases += 1 }
            released.fulfill()
        }
        func cancel() { lock.withLock { cancellations += 1 } }
        func observedCancelledTask(_ value: Bool) { lock.withLock { cancelledTask = value } }
        var state: (release: Int, cancel: Int, taskCancelled: Bool) {
            lock.withLock { (releases, cancellations, cancelledTask) }
        }
    }

    private func binding(_ witness: Witness) -> (NativeLocalConsumerLease, OneShotRelease) {
        let lease = NativeLocalConsumerLease()
        let release = OneShotRelease(release: { witness.release($0) }, modelId: "owned", nativeConsumerLease: lease)
        return (lease, release)
    }

    func testCloseBeforeActivationPreservesErrorAndTypedTerminalWithoutChunks() async throws {
        for typed in [false, true] {
            let witness = Witness(expectation(description: "real release callback"))
            let (lease, release) = binding(witness)
            let prepared = try lease.startPreparation { true }
            _ = try await prepared.value
            let source = AsyncStream<GenerationEvent>.makeStream()
            source.continuation.yield(.chunk("must not escape after close"))
            if typed {
                source.continuation.yield(.terminal(cause: .watchdog, message: "upstream typed fault",
                                                    promptTokens: 17, completionTokens: 2))
            } else {
                source.continuation.yield(.error("upstream error"))
            }
            source.continuation.finish()
            let result = try MiMoV26ManagedMediaForwarding.handoff(
                upstream: source.stream, lease: lease, release: release,
                cancel: { witness.cancel() })
            lease.closeAndCancel()
            result.handoff.activate()
            var count = 0
            for await event in result.stream {
                count += 1
                switch event {
                case .error(let message):
                    XCTAssertFalse(typed); XCTAssertEqual(message, "upstream error")
                case .terminal(let cause, let message, let prompt, let completion):
                    XCTAssertTrue(typed); XCTAssertEqual(cause, .watchdog)
                    XCTAssertEqual(message, "upstream typed fault")
                    XCTAssertEqual(prompt, 17); XCTAssertEqual(completion, 2)
                default: XCTFail("post-close content or synthesized success")
                }
            }
            await fulfillment(of: [witness.released], timeout: 5)
            await lease.joinFromOutside()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(witness.state.release, 1)
            XCTAssertEqual(witness.state.cancel, 1)
            XCTAssertEqual(lease.snapshot().phase, .completed)
        }
    }

    func testCloseBeforeRegistrationDrainsWithinStillOwnedPreparation() async throws {
        let witness = Witness(expectation(description: "late registered drainer release"))
        let (lease, release) = binding(witness)
        let entered = expectation(description: "preparation owns upstream")
        let gate = NativeLocalTaskStartGate()
        let source = AsyncStream<GenerationEvent>.makeStream()
        source.continuation.yield(.error("already produced failure"))
        source.continuation.finish()
        let preparation = try lease.startPreparation {
            entered.fulfill()
            await gate.wait()
            let result = try MiMoV26ManagedMediaForwarding.handoff(
                upstream: source.stream, lease: lease, release: release,
                cancel: { witness.cancel() })
            result.handoff.activate() // Never waits for caller activation.
            return result.stream
        }
        await fulfillment(of: [entered], timeout: 5)
        lease.closeAndCancel()
        gate.open()
        let stream = try await preparation.value
        var messages: [String] = []
        for await event in stream {
            if case .error(let message) = event { messages.append(message) }
            else { XCTFail("expected actual upstream error only") }
        }
        await fulfillment(of: [witness.released], timeout: 5)
        await lease.joinFromOutside()
        XCTAssertEqual(messages, ["already produced failure"])
        XCTAssertEqual(witness.state.release, 1)
        XCTAssertEqual(witness.state.cancel, 1)
    }

    func testHandoffCancelAndTerminationStillInvokeOneRealCancellation() async throws {
        let witness = Witness(expectation(description: "cancelled handoff release"))
        let (lease, release) = binding(witness)
        let preparation = try lease.startPreparation { true }
        _ = try await preparation.value
        let source = AsyncStream<GenerationEvent>.makeStream()
        let cancellationGate = NativeLocalTaskStartGate()
        source.continuation.yield(.chunk("pending content must not escape"))
        let result = try MiMoV26ManagedMediaForwarding.handoff(
            upstream: source.stream, lease: lease, release: release, cancel: {
                witness.cancel()
                await cancellationGate.wait()
                source.continuation.yield(.error("bridge cancellation terminal"))
                source.continuation.finish()
            })
        result.handoff.cancel()
        XCTAssertEqual(lease.snapshot().phase, .closing)
        result.handoff.terminate()
        result.handoff.activate()
        cancellationGate.open()
        var messages: [String] = []
        for await event in result.stream {
            if case .error(let message) = event { messages.append(message) }
            else { XCTFail("no post-close content") }
        }
        await fulfillment(of: [witness.released], timeout: 5)
        await lease.joinFromOutside()
        XCTAssertEqual(messages, ["bridge cancellation terminal"])
        XCTAssertEqual(witness.state.cancel, 1)
        XCTAssertEqual(witness.state.release, 1)
    }

    func testEOFWithoutTerminalIsFailureNotSuccess() async throws {
        let witness = Witness(expectation(description: "EOF release"))
        let (lease, release) = binding(witness)
        let preparation = try lease.startPreparation { true }
        _ = try await preparation.value
        let source = AsyncStream<GenerationEvent>.makeStream()
        source.continuation.finish()
        let result = try MiMoV26ManagedMediaForwarding.handoff(
            upstream: source.stream, lease: lease, release: release, cancel: { witness.cancel() })
        result.handoff.activate()
        var failures = 0
        for await event in result.stream {
            if case .error(let message) = event {
                XCTAssertEqual(message, "native media stream closed without a terminal event")
                failures += 1
            } else { XCTFail("must not fabricate success") }
        }
        await fulfillment(of: [witness.released], timeout: 5)
        await lease.joinFromOutside()
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(witness.state.release, 1)
    }

    func testDefaultForwardingStillCancelsItsTask() async throws {
        let witness = Witness(expectation(description: "default behavior release"))
        let (lease, release) = binding(witness)
        let preparation = try lease.startPreparation { true }
        _ = try await preparation.value
        let handoff = try lease.makeForwardingHandoff(cancel: {
            witness.cancel(); await release.fire()
        }, operation: {
            witness.observedCancelledTask(Task.isCancelled)
            await release.fire()
        })
        lease.closeAndCancel()
        handoff.terminate()
        handoff.activate()
        await handoff.task.value
        await fulfillment(of: [witness.released], timeout: 5)
        await lease.joinFromOutside()
        XCTAssertTrue(witness.state.taskCancelled)
        XCTAssertEqual(witness.state.release, 1)
        XCTAssertEqual(witness.state.cancel, 1)
    }
}
