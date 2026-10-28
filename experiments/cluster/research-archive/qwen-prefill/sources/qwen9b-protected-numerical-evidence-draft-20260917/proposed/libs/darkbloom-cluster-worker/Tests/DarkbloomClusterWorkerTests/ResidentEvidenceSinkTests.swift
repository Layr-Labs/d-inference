import Darwin
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

final class ResidentEvidenceSinkTests: XCTestCase {
    private enum Stop: Error { case cancelled }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: path) }
        return path
    }

    func testCreateOnlyExactRequestNamePrivateModeAndOriginalBytes() throws {
        let path = try directory(), sink = try ResidentEvidenceSink(path: path.path), id = UUID()
        let bytes = Data("{\"fixtureOnly\":true}".utf8)
        try sink.publish(bytes, requestID: id, deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        let file = path.appendingPathComponent(id.uuidString.lowercased() + ".json")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try sink.publish(Data("replacement".utf8), requestID: id,
            deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testPrivateDirectoryAndPrepublicationDeadlineOrResourceRefusal() throws {
        let path = try directory()
        XCTAssertEqual(chmod(path.path, 0o755), 0)
        XCTAssertThrowsError(try ResidentEvidenceSink(path: path.path))
        XCTAssertEqual(chmod(path.path, 0o700), 0)
        let link = path.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path.path)
        XCTAssertThrowsError(try ResidentEvidenceSink(path: link.path))
        let sink = try ResidentEvidenceSink(path: path.path), id = UUID()
        XCTAssertThrowsError(try sink.publish(Data("{}".utf8), requestID: id, deadline: 0))
        XCTAssertThrowsError(try sink.publish(Data("{}".utf8), requestID: id,
            deadline: DispatchTime.now().uptimeNanoseconds + 2_000_000_000, resourceCheck: { throw Stop.cancelled }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(id.uuidString.lowercased() + ".json").path))
    }
    func testMidWriteCancellationRetainsPartialFailureAndNeverReplacesIt() throws {
        let path = try directory(), sink = try ResidentEvidenceSink(path: path.path), id = UUID()
        var observations = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        XCTAssertThrowsError(try sink.publish(Data(repeating: 7, count: 131_072), requestID: id,
            deadline: deadline, resourceCheck: {
                observations += 1
                if observations == 3 { throw Stop.cancelled }
            }))
        let file = path.appendingPathComponent(id.uuidString.lowercased() + ".json")
        XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 7, count: 65_536))
        XCTAssertThrowsError(try sink.publish(Data("{}".utf8), requestID: id, deadline: deadline))
        XCTAssertEqual(try Data(contentsOf: file).count, 65_536)
    }
}
