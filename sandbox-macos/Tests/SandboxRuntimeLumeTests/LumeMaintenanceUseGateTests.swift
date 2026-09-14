import Foundation
@testable import SandboxRuntimeLume
import XCTest

final class LumeMaintenanceUseGateTests: XCTestCase {
    func testOverlappingWorkCannotReleaseOrReplaceTheLiveClaim() throws {
        let gate = LumeMaintenanceUseGate()
        XCTAssertThrowsError(try gate.withActiveClaim { XCTFail("spawn permitted without image ownership") })
        try gate.enter()
        XCTAssertEqual(try gate.withActiveClaim { "owned" }, "owned")
        let completed = expectation(description: "overlapping work rejected")
        DispatchQueue.global().async {
            do { try gate.enter(); XCTFail("overlapping work acquired the live claim") }
            catch LumeImageMaintenanceError.operationInProgress {}
            catch { XCTFail("unexpected error: \(error)") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        XCTAssertThrowsError(try gate.enter(), "rejection must preserve the first claim")
        gate.leave()
        XCTAssertThrowsError(try gate.withActiveClaim { XCTFail("spawn permitted after image callback returned") })
        try gate.enter(); gate.leave()
    }
}
