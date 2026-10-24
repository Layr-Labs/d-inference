import DarkbloomClusterProtocol
import Foundation
import XCTest

/// The queue/control-starvation regression reproduced before the Qwen fix.
/// The fabricated runtime now uses Qwen's production decision-progress helper
/// through the real coordinator. No native model/GPU/transport is constructed.
final class WorkerLaneJoinReproductionTests: XCTestCase {
    func testJoiningReservationIsAdmittedBeforeTheExistingLanesTokenDecision() throws {
        let h = try LanePipeHarness(pollsBatchDecisions: true), a = UUID(), b = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        try h.send(.reserve(h.reservation), id: a)
        try expect(h, .admitted(reservedBytes: 1024), id: a)
        try h.send(.start, id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)

        // Publication is the rendezvous: A's answer is deliberately withheld.
        // B has free capacity and must be admitted before that answer arrives.
        try h.send(.reserve(h.reservation), id: b)
        var admittedBeforeDecision = false
        do {
            let event = try h.event()
            XCTAssertEqual(event.requestID, b)
            XCTAssertEqual(event.event, .admitted(reservedBytes: 1024))
            admittedBeforeDecision = event.requestID == b && event.event == .admitted(reservedBytes: 1024)
        } catch {
            XCTAssertTrue(String(describing: error).contains("Test event timeout/bound"),
                "Expected bounded control starvation, not a worker failure: \(error)")
        }

        // Always unblock the fixture, including on the known failure. The
        // delayed ACK after A's decision distinguishes starvation from refusal.
        try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: a)
        try expect(h, .finished(.length), id: a)
        try expect(h, .retired(.clean), id: a)
        if !admittedBeforeDecision {
            try expect(h, .admitted(reservedBytes: 1024), id: b)
            print("{\"reproduced\":true,\"reserveAcknowledgedOnlyAfterExistingDecision\":true,\"modelExecution\":false}")
        }
        try h.send(.cancel(.callerCancelled), id: b)
        try expect(h, .retired(.cancelled), id: b)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertTrue(h.result.exitReasons.isEmpty)
        XCTAssertTrue(h.runtime.heldRequests.isEmpty)
        XCTAssertTrue(admittedBeforeDecision,
            "Joining B waited for A's token decision although a lane was free; synchronous provider admission can withhold that same decision")
    }

    /// The provider's serialized admit/receive dependency, with its queue
    /// fabricated but the worker coordinator, protocol and pipes unchanged.
    func testSerializedAdmissionWithholdsTheDecisionNeededByItsReservation() throws {
        let h = try LanePipeHarness(pollsBatchDecisions: true), a = UUID(), b = UUID()
        try expect(h, .ready(h.runtime.ready), id: nil)
        try h.send(.reserve(h.reservation), id: a)
        try expect(h, .admitted(reservedBytes: 1024), id: a)
        try h.send(.start, id: a)
        try expect(h, .committedToken(ordinal: 0, tokenID: 7, committedTokens: 3), id: a)

        let providerQueue = DispatchQueue(label: "test.serialized-provider")
        let enteredReserve = DispatchSemaphore(value: 0)
        let completed = DispatchGroup(), state = JoinCycleState(), shared = JoinCycleHarness(h)
        completed.enter()
        providerQueue.async {
            let h = shared.value
            defer { completed.leave() }
            do {
                try h.send(.reserve(h.reservation), id: b)
                enteredReserve.signal()
                // A real event router delivers these to A independently. Keep
                // them here only so a failed diagnostic can cleanly unwind.
                while true {
                    let event = try h.event()
                    if event.requestID == b {
                        guard event.event == .admitted(reservedBytes: 1024) else {
                            throw JoinCycleFailure.unexpectedReservationEvent
                        }
                        state.admitted()
                        break
                    }
                    state.record(event)
                }
            } catch { state.fail(error); enteredReserve.signal() }
        }
        XCTAssertEqual(enteredReserve.wait(timeout: .now() + 1), .success)
        completed.enter()
        providerQueue.async {
            let h = shared.value
            defer { completed.leave() }
            if state.callbackNeedsDecision() {
                do { try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: a) }
                catch { state.fail(error) }
            }
        }
        let progressed = completed.wait(timeout: .now() + 0.25) == .success
        let cycleObserved = !progressed && !state.didAdmit && !state.didCallBack
        // A bounded escape breaks the dependency without representing a
        // timeout as successful admission. The queued callback sees rescue
        // and must not send a duplicate token decision.
        if !progressed {
            state.rescue()
            try h.send(.tokenDecision(ordinal: 0, decision: .proceed), id: a)
        }
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)
        XCTAssertNil(state.error)
        XCTAssertTrue(state.didAdmit)
        XCTAssertTrue(state.didCallBack)
        var completedA = state.events
        while completedA.count < 2 { completedA.append(try h.event()) }
        XCTAssertEqual(completedA.map(\.requestID), [a, a])
        XCTAssertEqual(completedA.map(\.event), [.finished(.length), .retired(.clean)])
        try h.send(.cancel(.callerCancelled), id: b)
        try expect(h, .retired(.cancelled), id: b)
        try h.send(.shutdown)
        try expect(h, .shutdownComplete, id: nil)
        XCTAssertEqual(h.done.wait(timeout: .now() + 3), .success)
        XCTAssertNil(h.result.error)
        XCTAssertTrue(h.result.exitReasons.isEmpty)
        XCTAssertTrue(h.runtime.heldRequests.isEmpty)
        print("{\"providerQueueCycleObserved\":\(cycleObserved),\"realWorkerCoordinator\":true,\"realProviderEngine\":false,\"modelExecution\":false}")
        XCTAssertFalse(cycleObserved,
            "Reserve holds the provider queue, A's callback waits for that queue, and the worker waits for A's decision")
    }

    private func expect(_ h: LanePipeHarness, _ event: ClusterWorkerEvent, id: UUID?,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try h.event()
        XCTAssertEqual(actual.requestID, id, file: file, line: line)
        XCTAssertEqual(actual.event, event, file: file, line: line)
    }
}

private enum JoinCycleFailure: Error { case unexpectedReservationEvent }

private final class JoinCycleState: @unchecked Sendable {
    private let lock = NSLock()
    private var rescued = false, admittedValue = false, callbackValue = false
    private var eventValues: [ClusterWorkerEventFrame] = []
    private var errorValue: Error?
    func admitted() { lock.withLock { admittedValue = true } }
    func rescue() { lock.withLock { rescued = true } }
    func callbackNeedsDecision() -> Bool {
        lock.withLock { callbackValue = true; return !rescued }
    }
    func record(_ event: ClusterWorkerEventFrame) { lock.withLock { eventValues.append(event) } }
    func fail(_ error: Error) { lock.withLock { errorValue = error } }
    var didAdmit: Bool { lock.withLock { admittedValue } }
    var didCallBack: Bool { lock.withLock { callbackValue } }
    var events: [ClusterWorkerEventFrame] { lock.withLock { eventValues } }
    var error: Error? { lock.withLock { errorValue } }
}

// Every send/read is ordered by the rendezvous and provider queue above.
private final class JoinCycleHarness: @unchecked Sendable {
    let value: LanePipeHarness
    init(_ value: LanePipeHarness) { self.value = value }
}
