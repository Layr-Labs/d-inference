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
            executable: "xcodebuild",
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/env",
            environment: ["BAD-KEY": "value"],
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/env",
            environment: ["ÜNICODE": "value"],
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/bin/sleep",
            workingDirectory: "/tmp",
            timeoutSeconds: 901
        ))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: ["bad\0argument"],
            workingDirectory: "/tmp"
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
            arguments: [maximumValue],
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: [maximumValue + "x"],
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: Array(
                repeating: "x",
                count:
                    SandboxGuestCommandRequest.maximumArgumentCount + 1
            ),
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/env",
            environment: Dictionary(
                uniqueKeysWithValues: (0...SandboxGuestCommandRequest
                    .maximumEnvironmentVariableCount).map {
                        ("KEY_\($0)", "value")
                    }
            ),
            workingDirectory: "/tmp"
))
        XCTAssertThrowsError(try SandboxGuestCommandRequest(
            idempotencyKey: UUID(),
            executable: "/usr/bin/printf",
            arguments: Array(repeating: maximumValue, count: 5),
            workingDirectory: "/tmp"
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
                    environment: [key: "attacker-controlled"],
                    workingDirectory: "/tmp"
),
                "reserved environment key \(key) must be rejected"
            )
        }
    }
}
