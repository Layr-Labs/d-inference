import XCTest
@testable import ProviderCore

final class PreparedLeaseTests: XCTestCase {
    func testNoEmissionBeforeDurableStart() throws {
        var state = PreparedLeaseState.idle
        state = try PreparedLeaseReducer.transition(state, .beginPrepare(jobId: "j", attemptId: "a"))
        state = try PreparedLeaseReducer.transition(state, .markPrepared(leaseId: "l", prefillRunning: true))
        state = try PreparedLeaseReducer.transition(state, .start)
        XCTAssertThrowsError(try PreparedLeaseReducer.transition(state, .beginEmit)) { err in
            XCTAssertEqual(err as? PreparedLeaseError, .emissionBeforeDurableStart)
        }
    }

    func testAbortTombstoneRejectsStart() throws {
        var state = PreparedLeaseState.idle
        state = try PreparedLeaseReducer.transition(state, .beginPrepare(jobId: "j", attemptId: "a"))
        state = try PreparedLeaseReducer.transition(state, .markPrepared(leaseId: "l", prefillRunning: true))
        state = try PreparedLeaseReducer.transition(state, .abort(leaseId: "l"))
        XCTAssertThrowsError(try PreparedLeaseReducer.transition(state, .start)) { err in
            XCTAssertEqual(err as? PreparedLeaseError, .abortTombstone)
        }
    }

    func testHappyPathToAck() throws {
        var state = PreparedLeaseState.idle
        state = try PreparedLeaseReducer.transition(state, .beginPrepare(jobId: "j", attemptId: "a"))
        state = try PreparedLeaseReducer.transition(state, .markPrepared(leaseId: "l", prefillRunning: true))
        state = try PreparedLeaseReducer.transition(state, .start)
        state = try PreparedLeaseReducer.transition(state, .startDurable)
        state = try PreparedLeaseReducer.transition(state, .beginEmit)
        state = try PreparedLeaseReducer.transition(state, .journalTerminal)
        state = try PreparedLeaseReducer.transition(state, .ackTerminal)
        XCTAssertEqual(state, .acknowledged)
    }
}
