import Foundation
import SandboxRuntime
import XCTest

final class GuestCommandTests: XCTestCase {
    func testAcceptsBoundedAbsoluteCommand() throws {
        let request = try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            environment: ["CI": "1"],
            workingDirectory: "/Users/lume/workspace",
            timeoutSeconds: 900
        )

        XCTAssertEqual(request.timeoutSeconds, 900)
        XCTAssertEqual(request.environment, ["CI": "1"])
    }

    func testRejectsUnboundedOrAmbiguousCommandInputs() {
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "xcodebuild"
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/env",
            environment: ["BAD-KEY": "value"]
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/sleep",
            timeoutSeconds: 901
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: ["bad\0argument"]
        ))
    }
}
