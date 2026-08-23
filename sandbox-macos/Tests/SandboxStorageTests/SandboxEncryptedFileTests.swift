import Foundation
import SandboxCore
import SandboxStorage
import XCTest

final class SandboxEncryptedFileTests: XCTestCase {
    func testRoundTripAcrossMultipleChunks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let plaintext = Data((0..<220_000).map { UInt8($0 % 251) })
        try plaintext.write(to: fixture.plaintext)

        let codec = try SandboxEncryptedFileCodec(chunkSize: 65_536)
        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )
        try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: fixture.key,
            context: fixture.context
        )

        XCTAssertEqual(try Data(contentsOf: fixture.decrypted), plaintext)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: fixture.encrypted.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testEmptyFileIsAuthenticatedAndRoundTrips() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.plaintext)
        let codec = try SandboxEncryptedFileCodec()

        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )
        try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: fixture.key,
            context: fixture.context
        )
        XCTAssertEqual(try Data(contentsOf: fixture.decrypted), Data())
    }

    func testWrongKeyCannotCreatePlaintextDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("classified workspace".utf8).write(to: fixture.plaintext)
        let codec = try SandboxEncryptedFileCodec()
        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )

        XCTAssertThrowsError(try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: .generate(),
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? SandboxEncryptedFileError, .authenticationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.decrypted.path))
    }

    func testCiphertextTamperAndTruncationAreRejectedAtomically() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(repeating: 0xA5, count: 100_000).write(to: fixture.plaintext)
        let codec = try SandboxEncryptedFileCodec(chunkSize: 65_536)
        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )

        var encrypted = try Data(contentsOf: fixture.encrypted)
        encrypted[100] ^= 0x80
        try encrypted.write(to: fixture.encrypted, options: .atomic)
        XCTAssertThrowsError(try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: fixture.key,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? SandboxEncryptedFileError, .authenticationFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.decrypted.path))

        try FileManager.default.removeItem(at: fixture.encrypted)
        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )
        encrypted = try Data(contentsOf: fixture.encrypted)
        try encrypted.dropLast().write(to: fixture.encrypted, options: .atomic)
        XCTAssertThrowsError(try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: fixture.key,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? SandboxEncryptedFileError, .truncated)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.decrypted.path))
    }

    func testContextSwapAndTrailingBytesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("workspace".utf8).write(to: fixture.plaintext)
        let codec = try SandboxEncryptedFileCodec()
        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )
        let wrongContext = SandboxEncryptionContext(
            sandboxID: fixture.context.sandboxID,
            generation: fixture.context.generation,
            role: .bootDelta
        )
        XCTAssertThrowsError(try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: fixture.key,
            context: wrongContext
        )) { error in
            XCTAssertEqual(error as? SandboxEncryptedFileError, .contextMismatch)
        }

        let handle = try FileHandle(forWritingTo: fixture.encrypted)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00]))
        try handle.close()
        XCTAssertThrowsError(try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: fixture.key,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? SandboxEncryptedFileError, .trailingData)
        }
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("source".utf8).write(to: fixture.plaintext)
        try Data("keep".utf8).write(to: fixture.encrypted)
        let codec = try SandboxEncryptedFileCodec()

        XCTAssertThrowsError(try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: fixture.key,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? SandboxEncryptedFileError, .destinationExists)
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.encrypted),
            Data("keep".utf8)
        )
    }
}

private struct Fixture {
    let directory: URL
    let plaintext: URL
    let encrypted: URL
    let decrypted: URL
    let key: SandboxDataEncryptionKey
    let context: SandboxEncryptionContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-sandbox-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        plaintext = directory.appendingPathComponent("plain")
        encrypted = directory.appendingPathComponent("encrypted")
        decrypted = directory.appendingPathComponent("decrypted")
        key = .generate()
        context = SandboxEncryptionContext(
            sandboxID: SandboxID(),
            generation: SandboxGeneration(rawValue: 1)!,
            role: .workspace
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
