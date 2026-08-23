import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestCommandResultDecoderTests: XCTestCase {
    func testDecodesBoundedBinaryStreams() throws {
        let standardOutput = Data([0x00, 0x01, 0xFF])
        let standardError = Data("error".utf8)
        let result = try LumeGuestCommandResultDecoder.decode(
            envelope(
                standardOutput: standardOutput,
                standardError: standardError,
                exitCode: 17,
                standardOutputTruncated: true
            )
        )

        XCTAssertEqual(result.exitCode, 17)
        XCTAssertEqual(result.standardOutput, standardOutput)
        XCTAssertEqual(result.standardError, standardError)
        XCTAssertTrue(result.standardOutputTruncated)
        XCTAssertFalse(result.standardErrorTruncated)
        XCTAssertFalse(result.timedOut)
    }

    func testRejectsMismatchedLengthsAndOversizedEnvelope() throws {
        let malformed = try JSONSerialization.data(
            withJSONObject: [
                "magic": LumeGuestCommandEnvelope.magic,
                "schema_version": LumeGuestCommandEnvelope.schemaVersion,
                "exit_code": 0,
                "stdout_length": 2,
                "stderr_length": 0,
                "stdout_truncated": false,
                "stderr_truncated": false,
                "timed_out": false,
                "stdout_base64": Data([0x01]).base64EncodedString(),
                "stderr_base64": "",
            ],
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try LumeGuestCommandResultDecoder.decode(malformed)
        ) { error in
            XCTAssertEqual(
                error as? SandboxRuntimeError,
                .malformedOutput(
                    "Lume guest-command result envelope is invalid"
                )
            )
        }
        XCTAssertThrowsError(
            try LumeGuestCommandResultDecoder.decode(
                Data(
                    count:
                        LumeGuestCommandEnvelope.maximumEnvelopeBytes + 1
                )
            )
        )
    }

    func testRejectsExitCodeOutsideProcessRange() throws {
        for exitCode: Int32 in [-1, 256] {
            XCTAssertThrowsError(
                try LumeGuestCommandResultDecoder.decode(
                    envelope(
                        standardOutput: Data(),
                        standardError: Data(),
                        exitCode: exitCode
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? SandboxRuntimeError,
                    .malformedOutput(
                        "Lume guest-command result envelope is invalid"
                    )
                )
            }
        }
    }

    func testDecodesGuestLocalDeadline() throws {
        let result = try LumeGuestCommandResultDecoder.decode(
            envelope(
                standardOutput: Data(),
                standardError: Data(),
                exitCode: 124,
                timedOut: true
            )
        )

        XCTAssertEqual(result.exitCode, 124)
        XCTAssertTrue(result.timedOut)
        XCTAssertThrowsError(
            try LumeGuestCommandResultDecoder.decode(
                envelope(
                    standardOutput: Data(),
                    standardError: Data(),
                    exitCode: 0,
                    timedOut: true
                )
            )
        )
    }

    private func envelope(
        standardOutput: Data,
        standardError: Data,
        exitCode: Int32,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false,
        timedOut: Bool = false
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "magic": LumeGuestCommandEnvelope.magic,
                "schema_version": LumeGuestCommandEnvelope.schemaVersion,
                "exit_code": exitCode,
                "stdout_length": standardOutput.count,
                "stderr_length": standardError.count,
                "stdout_truncated": standardOutputTruncated,
                "stderr_truncated": standardErrorTruncated,
                "timed_out": timedOut,
                "stdout_base64": standardOutput.base64EncodedString(),
                "stderr_base64": standardError.base64EncodedString(),
            ],
            options: [.sortedKeys]
        )
    }
}
