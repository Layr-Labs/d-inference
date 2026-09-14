import Foundation
import SandboxGuestProtocol
@testable import SandboxGuestRuntime
import XCTest

final class GuestWorkerPayloadTests: XCTestCase {
    func testMaximumControlCharacterArgumentsRoundTripBelowWorkerLimit() throws {
        let command = GuestCommand(executable: "/usr/bin/printf",
            arguments: (0..<4).map { _ in String(repeating: "\u{1}", count: 16000) })
        try command.validate()
        XCTAssertGreaterThan(try JSONEncoder().encode(command).count, GuestWorkerPayload.maximumDecodedBytes)
        let encoded = try GuestWorkerPayload.encode(command)
        XCTAssertLessThan(encoded.utf8.count, GuestWorkerPayload.maximumEncodedBytes)
        XCTAssertEqual(try GuestWorkerPayload.decode(encoded), command)
    }

    func testMaximumEnvironmentAndUnicodeArgumentsRoundTrip() throws {
        let command = GuestCommand(executable: "/usr/bin/printf",
            arguments: [String(repeating: "😀", count: 4000), String(repeating: "\"\\\n", count: 5000)],
            environment: ["TEXT": String(repeating: "\u{1}", count: 16000)])
        XCTAssertEqual(try GuestWorkerPayload.decode(GuestWorkerPayload.encode(command)), command)
    }

    func testMalformedOversizeAndInvalidDecodedCommandsAreRejected() throws {
        XCTAssertThrowsError(try GuestWorkerPayload.decode(String(repeating: "A", count: GuestWorkerPayload.maximumEncodedBytes + 4)))
        XCTAssertThrowsError(try GuestWorkerPayload.decode(Data("{}".utf8).base64EncodedString()))
        XCTAssertThrowsError(try GuestWorkerPayload.encode(GuestCommand(executable: "relative")))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let bad = try encoder.encode(GuestCommand(executable: "/bin/sh", environment: ["DYLD_INSERT_LIBRARIES": "bad"]))
        XCTAssertThrowsError(try GuestWorkerPayload.decode(bad.base64EncodedString()))
    }
}
