import Foundation
import SandboxGuestProtocol
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeIsolatedGuestResultTests: XCTestCase {
    private func response(timedOut: Bool = false) -> GuestResponse {
        var result = GuestResponse(id: UUID(), success: !timedOut)
        result.exitCode = timedOut ? 143 : 0
        result.standardOutput = Data("partial output".utf8)
        result.standardError = Data()
        result.standardOutputTruncated = false
        result.standardErrorTruncated = false
        result.timedOut = timedOut
        result.cancelled = false
        result.requiresVMStop = false
        return result
    }

    func testCleanTimeoutSurvivesFailedGuestStatusAndJournalEnvelopeRoundTrip() throws {
        let guest = response(timedOut: true)
        XCTAssertFalse(guest.success)
        let envelope = try LumeIsolatedGuestResult.envelope(guest)
        let journalResult = try LumeGuestCommandResultDecoder.decode(envelope)
        XCTAssertTrue(journalResult.timedOut)
        XCTAssertEqual(journalResult.standardOutput, Data("partial output".utf8))
        XCTAssertEqual(journalResult.exitCode, 124)
    }

    func testMissingOrUncertainCleanupProofStillRejectsTimeout() throws {
        var unproven = response(timedOut: true)
        unproven.requiresVMStop = true
        XCTAssertThrowsError(try LumeIsolatedGuestResult.envelope(unproven))
        unproven.requiresVMStop = nil
        XCTAssertThrowsError(try LumeIsolatedGuestResult.envelope(unproven))
        unproven.requiresVMStop = false
        unproven.cancelled = true
        XCTAssertThrowsError(try LumeIsolatedGuestResult.envelope(unproven))
    }

    func testCompleteSuccessAndNonTimeoutProtocolFailureStayDistinct() throws {
        let normal = try LumeGuestCommandResultDecoder.decode(LumeIsolatedGuestResult.envelope(response()))
        XCTAssertFalse(normal.timedOut)
        XCTAssertEqual(normal.exitCode, 0)
        var rejected = GuestResponse(id: UUID(), success: false, errorCode: "guest_busy")
        rejected.requiresVMStop = false
        XCTAssertThrowsError(try LumeIsolatedGuestResult.envelope(rejected))
    }
}
