import Foundation
import SandboxCore
import XCTest

final class SandboxFileProtocolTests: XCTestCase {
    func testUploadChunkMatchesGoContract() throws {
        let frame = Data(#"{"type":"sandbox_file_operation","protocol_version":1,"host_id":"00000000-0000-0000-0000-000000000001","connection_epoch":"00000000-0000-0000-0000-000000000002","sequence":3,"payload":{"request_id":"00000000-0000-0000-0000-000000000003","scope":{"sandbox_id":"00000000-0000-0000-0000-000000000004","generation":1,"fencing_token":2},"operation":"upload_chunk","transfer_id":"00000000-0000-0000-0000-000000000005","offset":0,"data":"YWJj"}}"#.utf8)
        guard case .fileOperation(let decoded) = try SandboxControlCodec.decodeCoordinatorMessage(frame) else {
            return XCTFail("expected file operation")
        }
        XCTAssertEqual(decoded.payload.operation, .uploadChunk)
        XCTAssertEqual(decoded.payload.data, Data("abc".utf8))
        XCTAssertEqual(decoded.payload.offset, 0)
        XCTAssertNil(decoded.payload.path)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: frame) as? NSDictionary)
        for field in [#""credential":"secret""#, #""command":{"executable":"/bin/sh"}"#, #""configuration":{}"#] {
            let modified = String(decoding: frame, as: UTF8.self).replacingOccurrences(of: #""operation":"upload_chunk""#, with: #""operation":"upload_chunk","# + field)
            XCTAssertThrowsError(try SandboxControlCodec.decodeCoordinatorMessage(Data(modified.utf8)))
        }
    }

    func testFilePathsAndChunkBounds() throws {
        let scope = try scope()
        for path in ["", "/etc/passwd", "../escape", "src/../escape", "src//main", "src/./main", "src/", "nul\0name", String(repeating: "a", count: 256)] {
            XCTAssertFalse(SandboxFileWireValidation.validPath(path), "accepted \(path)")
            let payload = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .mkdir, path: path)
            XCTAssertFalse(SandboxFileWireValidation.validate(payload))
        }
        let valid = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .uploadChunk,
            transferID: UUID(), offset: 0, data: Data(repeating: 1, count: SandboxFileWireValidation.maximumChunkBytes))
        XCTAssertTrue(SandboxFileWireValidation.validate(valid))
        let excessive = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .uploadChunk,
            transferID: UUID(), offset: 0, data: Data(repeating: 1, count: SandboxFileWireValidation.maximumChunkBytes + 1))
        XCTAssertFalse(SandboxFileWireValidation.validate(excessive))
        let unexpected = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .mkdir,
            transferID: UUID(), path: "src")
        XCTAssertFalse(SandboxFileWireValidation.validate(unexpected))
    }

    func testCommandWorkspaceAndEnvironmentMatchGuestBoundary() throws {
        for directory in ["/Users/lume", "/workspace/..", "/workspace//src", "/workspace/", "/workspace-other"] {
            let command = SandboxWireCommand(commandID: UUID(), idempotencyKey: UUID().uuidString,
                scope: try scope(), arguments: ["/usr/bin/true"], workingDirectory: directory, timeoutSeconds: 30)
            XCTAssertThrowsError(try SandboxControlCodec.decodeCoordinatorMessage(JSONEncoder().encode(envelope(command))))
        }
        for key in ["HOME", "PATH", "TMPDIR", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "DYLD_INSERT_LIBRARIES", "DARKBLOOM_TOKEN"] {
            let command = SandboxWireCommand(commandID: UUID(), idempotencyKey: UUID().uuidString,
                scope: try scope(), arguments: ["/usr/bin/true"], environment: [key: "tenant"], timeoutSeconds: 30)
            XCTAssertThrowsError(try SandboxControlCodec.decodeCoordinatorMessage(JSONEncoder().encode(envelope(command))))
        }
    }

    func testDownloadRequiresVersionForLaterChunks() throws {
        let scope = try scope()
        let initial = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .download,
            path: "artifact.bin", offset: 0, size: 512)
        XCTAssertTrue(SandboxFileWireValidation.validate(initial))
        let later = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .download,
            path: "artifact.bin", offset: 512, size: 512)
        XCTAssertFalse(SandboxFileWireValidation.validate(later))
        let bound = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .download,
            path: "artifact.bin", offset: 512, size: 512, version: String(repeating: "a", count: 64))
        let envelope = SandboxControlEnvelope(type: .fileOperation, hostID: UUID(), connectionEpoch: UUID(), sequence: 1, payload: bound)
        guard case .fileOperation(let decoded) = try SandboxControlCodec.decodeCoordinatorMessage(JSONEncoder().encode(envelope)) else {
            return XCTFail("expected file operation")
        }
        XCTAssertEqual(decoded.payload, bound)
        let wrongOperation = SandboxWireFileOperation(requestID: UUID(), scope: scope, operation: .mkdir,
            path: "directory", version: String(repeating: "a", count: 64))
        XCTAssertFalse(SandboxFileWireValidation.validate(wrongOperation))
    }

    private func envelope(_ command: SandboxWireCommand) -> SandboxControlEnvelope<SandboxWireCommand> {
        SandboxControlEnvelope(type: .command, hostID: UUID(), connectionEpoch: UUID(), sequence: 1, payload: command)
    }

    private func scope() throws -> SandboxWireScope {
        SandboxWireScope(sandboxID: try XCTUnwrap(SandboxID(UUID().uuidString)),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            fencingToken: try XCTUnwrap(SandboxFencingToken(rawValue: 2)))
    }
}
