import Foundation
import SandboxCore
import SandboxSecurity
import SandboxStorage
import XCTest

final class SandboxArtifactKeyStoreTests: XCTestCase {
    func testSecureEnclaveWrappedKeyEncryptsAndRestoresArtifact() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let fixture = try KeyFixture()
        defer { fixture.remove() }
        let enclaveKey = try SandboxSecureEnclaveKey.makeTransient()
        let keyStore = SandboxArtifactKeyStore(enclaveKey: enclaveKey)
        let originalKey = try keyStore.create(
            at: fixture.envelope,
            context: fixture.context
        )
        try Data("sandbox workspace payload".utf8).write(to: fixture.plaintext)
        let codec = try SandboxEncryptedFileCodec()
        try codec.encrypt(
            source: fixture.plaintext,
            destination: fixture.encrypted,
            key: originalKey,
            context: fixture.context
        )

        let restoredKey = try keyStore.load(
            from: fixture.envelope,
            context: fixture.context
        )
        XCTAssertEqual(
            restoredKey.rawRepresentation,
            originalKey.rawRepresentation
        )
        try codec.decrypt(
            source: fixture.encrypted,
            destination: fixture.decrypted,
            key: restoredKey,
            context: fixture.context
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.decrypted),
            Data("sandbox workspace payload".utf8)
        )
    }

    func testEnvelopeIsBoundToContextAndEnclaveIdentity() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let fixture = try KeyFixture()
        defer { fixture.remove() }
        let keyStore = SandboxArtifactKeyStore(
            enclaveKey: try SandboxSecureEnclaveKey.makeTransient()
        )
        _ = try keyStore.create(at: fixture.envelope, context: fixture.context)

        let wrongContext = SandboxEncryptionContext(
            sandboxID: fixture.context.sandboxID,
            generation: SandboxGeneration(rawValue: 2)!,
            role: fixture.context.role
        )
        XCTAssertThrowsError(try keyStore.load(
            from: fixture.envelope,
            context: wrongContext
        )) { error in
            XCTAssertEqual(error as? SandboxArtifactKeyStoreError, .contextMismatch)
        }

        let wrongKeyStore = SandboxArtifactKeyStore(
            enclaveKey: try SandboxSecureEnclaveKey.makeTransient()
        )
        XCTAssertThrowsError(try wrongKeyStore.load(
            from: fixture.envelope,
            context: fixture.context
        )) { error in
            XCTAssertEqual(
                error as? SandboxArtifactKeyStoreError,
                .keyIdentityMismatch
            )
        }
    }

    func testEnvelopeTamperAndUnsafePermissionsFailClosed() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let fixture = try KeyFixture()
        defer { fixture.remove() }
        let keyStore = SandboxArtifactKeyStore(
            enclaveKey: try SandboxSecureEnclaveKey.makeTransient()
        )
        _ = try keyStore.create(at: fixture.envelope, context: fixture.context)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.envelope)
            ) as? [String: Any]
        )
        var wrapped = try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(object["wrappedKey"] as? String))
        )
        wrapped[wrapped.count / 2] ^= 0x01
        object["wrappedKey"] = wrapped.base64EncodedString()
        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        try tampered.write(to: fixture.envelope, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.envelope.path
        )
        XCTAssertThrowsError(try keyStore.load(
            from: fixture.envelope,
            context: fixture.context
        )) { error in
            XCTAssertEqual(
                error as? SandboxArtifactKeyStoreError,
                .authenticationFailed
            )
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fixture.envelope.path
        )
        XCTAssertThrowsError(try keyStore.load(
            from: fixture.envelope,
            context: fixture.context
        )) { error in
            guard let typed = error as? SandboxArtifactKeyStoreError,
                  case .unsafePermissions = typed
            else {
                return XCTFail("expected unsafe permissions, got \(error)")
            }
        }
    }

    func testCreateNeverOverwritesExistingEnvelope() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let fixture = try KeyFixture()
        defer { fixture.remove() }
        try Data("keep".utf8).write(to: fixture.envelope)
        let keyStore = SandboxArtifactKeyStore(
            enclaveKey: try SandboxSecureEnclaveKey.makeTransient()
        )

        XCTAssertThrowsError(try keyStore.create(
            at: fixture.envelope,
            context: fixture.context
        )) { error in
            XCTAssertEqual(error as? SandboxArtifactKeyStoreError, .destinationExists)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.envelope), Data("keep".utf8))
    }

    func testLoadRejectsSymbolicLinkEnvelope() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let fixture = try KeyFixture()
        defer { fixture.remove() }
        let keyStore = SandboxArtifactKeyStore(
            enclaveKey: try SandboxSecureEnclaveKey.makeTransient()
        )
        _ = try keyStore.create(at: fixture.envelope, context: fixture.context)
        let target = fixture.directory.appendingPathComponent("workspace.target")
        try FileManager.default.moveItem(at: fixture.envelope, to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.envelope,
            withDestinationURL: target
        )

        XCTAssertThrowsError(try keyStore.load(
            from: fixture.envelope,
            context: fixture.context
        )) { error in
            XCTAssertEqual(
                error as? SandboxArtifactKeyStoreError,
                .invalidEnvelope
            )
        }
    }
}

private struct KeyFixture {
    let directory: URL
    let envelope: URL
    let plaintext: URL
    let encrypted: URL
    let decrypted: URL
    let context: SandboxEncryptionContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-sandbox-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        envelope = directory.appendingPathComponent("workspace.key")
        plaintext = directory.appendingPathComponent("workspace.raw")
        encrypted = directory.appendingPathComponent("workspace.enc")
        decrypted = directory.appendingPathComponent("workspace.out")
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
