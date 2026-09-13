import Darwin
import Foundation
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class BaseGuestInstallationReceiptWriterTests: XCTestCase, @unchecked Sendable {
    func testRealPlutilWriterPublishesTypedCompletePrivateJSON() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("receipt.json")
        let result = try await write(to: destination)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(result.standardOutput, data)
        let receipt = try JSONDecoder().decode(BaseGuestInstallationReceipt.self, from: data)
        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.guestSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(receipt.bootstrapSHA256, String(repeating: "b", count: 64))
        XCTAssertEqual(receipt.launchdSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(receipt.installerSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(receipt.guestOperatingSystemVersion, "26.0")
        XCTAssertEqual(receipt.guestArchitecture, "arm64")
        XCTAssertTrue(receipt.bootstrapRetired)
        var metadata = stat()
        XCTAssertEqual(lstat(destination.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["receipt.json"])
    }

    func testRealWriterEscapesValuesThroughPlistAndJSON() async throws {
        let destination = try temporaryDirectory().appendingPathComponent("receipt.json")
        let value = "26.0 \"quoted\" & <tag>\nline\\tail"
        let result = try await write(to: destination, operatingSystem: value)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
        let receipt = try JSONDecoder().decode(BaseGuestInstallationReceipt.self, from: result.standardOutput)
        XCTAssertEqual(receipt.guestOperatingSystemVersion, value)
    }

    func testRealWriterPreservesExistingReceiptAndRejectsSymlink() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("receipt.json")
        let retained = Data("retained incomplete attempt".utf8)
        try retained.write(to: destination)
        var result = try await write(to: destination)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: destination), retained)
        try FileManager.default.removeItem(at: destination)
        let victim = directory.appendingPathComponent("victim")
        try retained.write(to: victim)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: victim)
        result = try await write(to: destination)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: victim), retained)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["receipt.json", "victim"])
    }

    func testRealWriterFailureDoesNotPublishOrRetainPartialTemporaryFile() async throws {
        let directory = try temporaryDirectory()
        let destination = directory.appendingPathComponent("receipt.json")
        // Limit only this test subprocess's file output. The real plist writer
        // must fail and clean its temporary file before publishing a receipt.
        let result = try await write(to: destination, limitFileSize: true)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("base-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func write(to destination: URL, operatingSystem: String = "26.0",
                       limitFileSize: Bool = false) async throws -> SandboxProcessResult {
        try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", (limitFileSize ? "ulimit -f 1\n" : "") + BaseGuestInstallationReceiptWriter.shellFunction +
                "\nwrite_base_installation_receipt \"$@\"", "receipt-writer-test", destination.path,
                String(repeating: "a", count: 64), String(repeating: "b", count: 64),
                String(repeating: "c", count: 64), String(repeating: "d", count: 64), operatingSystem, "arm64"],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeoutSeconds: 10)
    }
}
