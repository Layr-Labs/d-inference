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
            executable: "/usr/bin/env",
            environment: ["ÜNICODE": "value"]
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

    func testEnforcesArgumentEnvironmentAndAggregateBudgets() throws {
        let maximumValue = String(
            repeating: "x",
            count: SandboxGuestCommandRequest.maximumValueBytes
        )
        XCTAssertNoThrow(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: [maximumValue]
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: [maximumValue + "x"]
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: Array(
                repeating: "x",
                count:
                    SandboxGuestCommandRequest.maximumArgumentCount + 1
            )
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/env",
            environment: Dictionary(
                uniqueKeysWithValues: (0...SandboxGuestCommandRequest
                    .maximumEnvironmentVariableCount).map {
                        ("KEY_\($0)", "value")
                    }
            )
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: Array(repeating: maximumValue, count: 5)
        ))
    }

    func testRejectsControlPlaneEnvironmentOverrides() {
        for key in [
            "BASH_ENV",
            "DARKBLOOM_RESULT_DIR",
            "DYLD_INSERT_LIBRARIES",
            "ENV",
            "HOME",
            "LANG",
            "LC_ALL",
            "PATH",
            "TMPDIR",
            "ZDOTDIR",
        ] {
            XCTAssertThrowsError(
                try SandboxGuestCommandRequest(
                    idempotencyKey: UUID(),
                    executable: "/usr/bin/env",
                    environment: [key: "attacker-controlled"]
                ),
                "reserved environment key \(key) must be rejected"
            )
        }
    }
}
