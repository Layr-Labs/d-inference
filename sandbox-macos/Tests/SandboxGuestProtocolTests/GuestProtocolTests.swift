import CryptoKit
import Foundation
import XCTest
@testable import SandboxGuestProtocol

final class GuestProtocolTests: XCTestCase {
    func testAuthenticationBindsInstanceChallengeDirectionAndPayload() throws {
        let id = UUID(), key = Data(repeating: 0x41, count: 32)
        let hello = try GuestHello(instanceID: id)
        var server = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: id, credential: key)
        let request = GuestRequest(operation: .ping)
        let frame = try server.seal(request, sequence: 1, direction: .request)
        XCTAssertEqual(try server.accept(frame), request)
        XCTAssertThrowsError(try server.accept(frame))
        XCTAssertThrowsError(try server.open(frame, as: GuestRequest.self, direction: .response))
        let other = try GuestSessionAuthenticator(hello: GuestHello(instanceID: id), expectedInstanceID: id, credential: key)
        XCTAssertThrowsError(try other.open(frame, as: GuestRequest.self, direction: .request))
        let wrongKey = try GuestSessionAuthenticator(hello: hello, expectedInstanceID: id, credential: Data(repeating: 0x42, count: 32))
        XCTAssertThrowsError(try wrongKey.open(frame, as: GuestRequest.self, direction: .request))
        let altered = GuestAuthenticatedFrame(sequence: 1, payload: Data("{}".utf8), authentication: frame.authentication)
        XCTAssertThrowsError(try server.open(altered, as: GuestRequest.self, direction: .request))
        XCTAssertThrowsError(try GuestSessionAuthenticator(hello: hello, expectedInstanceID: UUID(), credential: key))
    }

    func testInvalidAuthenticationDoesNotAdvanceSequence() throws {
        let id = UUID(), key = Data(repeating: 1, count: 32)
        var server = try GuestSessionAuthenticator(hello: GuestHello(instanceID: id), expectedInstanceID: id, credential: key)
        let frame = try server.seal(GuestRequest(operation: .ping), sequence: 1, direction: .request)
        let invalid = GuestAuthenticatedFrame(sequence: 1, payload: frame.payload, authentication: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try server.accept(invalid))
        XCTAssertNoThrow(try server.accept(frame))
    }

    func testFrameLengthRejectsZeroOversizeAndShortBeforeAllocation() throws {
        XCTAssertThrowsError(try GuestFrameCodec.frameSize(header: Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try GuestFrameCodec.frameSize(header: Data([255, 255, 255, 255])))
        XCTAssertThrowsError(try GuestFrameCodec.frameSize(header: Data([0, 1])))
        XCTAssertEqual(try GuestFrameCodec.frameSize(header: Data([0, 0, 1, 0])), 256)
        XCTAssertThrowsError(try GuestFrameCodec.decode(Data("{broken}".utf8), as: GuestRequest.self))
    }

    func testMaximumOutputRoundTripsThroughBothBase64Layers() throws {
        let id = UUID()
        let auth = try GuestSessionAuthenticator(hello: GuestHello(instanceID: id), expectedInstanceID: id, credential: Data(repeating: 7, count: 32))
        var result = GuestResponse(id: UUID(), success: true)
        result.standardOutput = Data(repeating: 0xfe, count: GuestProtocolLimits.maximumOutputBytes)
        result.standardError = Data(repeating: 0xff, count: GuestProtocolLimits.maximumOutputBytes)
        let signed = try auth.seal(result, sequence: 1, direction: .response)
        let frame = try GuestFrameCodec.encode(signed)
        XCTAssertEqual(try GuestFrameCodec.frameSize(header: frame.prefix(4)), frame.count - 4)
        let decoded = try GuestFrameCodec.decode(frame.dropFirst(4), as: GuestAuthenticatedFrame.self)
        XCTAssertEqual(try auth.open(decoded, as: GuestResponse.self, direction: .response), result)
    }

    func testCommandAndWorkspaceInputValidation() throws {
        XCTAssertNoThrow(try GuestCommand(executable: "/usr/bin/printf", arguments: ["%s", "$(touch evil)"]).validate())
        XCTAssertThrowsError(try GuestCommand(executable: "echo").validate())
        XCTAssertThrowsError(try GuestCommand(executable: "/bin/sh", environment: ["DYLD_INSERT_LIBRARIES": "x"]).validate())
        XCTAssertThrowsError(try GuestCommand(executable: "/bin/sh", environment: ["HOME": "x"]).validate())
        XCTAssertThrowsError(try GuestCommand(executable: "/bin/sh", timeoutSeconds: 901).validate())
        for path in ["/etc/passwd", "../a", "a/../../b", "a//b", "a/./b", "a/", "a\0b"] {
            XCTAssertThrowsError(try GuestPath.components(path), path)
        }
        XCTAssertEqual(try GuestPath.components("dir/file"), ["dir", "file"])
    }
}
