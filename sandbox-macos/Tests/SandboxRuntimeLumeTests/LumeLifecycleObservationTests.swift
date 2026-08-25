import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeLifecycleObservationTests: XCTestCase {
    func testStartUsesRecordThatSatisfiedRunningStateWait() async throws {
        let fixture = try FakeLumeFixture(
            behavior:
                "credentialed-readiness-regress-after-first-running-observation"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 4)

        try await runtime.start(name: fixture.virtualMachineName)

        XCTAssertTrue(fixture.runningStateProofWasConsumed)
        XCTAssertTrue(fixture.runningStateRegressionWasConsumed)
        let record = try await runtime.inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertEqual(record?.state, .running)

        try await runtime.stop(name: fixture.virtualMachineName)
    }
}
