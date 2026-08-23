import Darwin
import Foundation
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestCommandJournalTests: XCTestCase {
    func testCompletedCommandReplaysBoundedResult() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let request = try fixture.request()
        let expected = SandboxGuestCommandResult(
            exitCode: 7,
            standardOutput: Data("stdout".utf8),
            standardError: Data("stderr".utf8),
            standardOutputTruncated: false,
            standardErrorTruncated: true
        )

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .unclaimed
        )
        let claim = try fixture.journal.claim(
            installationID: installationID,
            request: request
        )
        try claim.complete(envelope: Self.envelope(for: expected))

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .completed(expected)
        )
    }

    func testClaimWithoutResultFailsClosedInsteadOfReexecuting() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let request = try fixture.request()

        _ = try fixture.journal.claim(
            installationID: installationID,
            request: request
        )

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .indeterminate
        )
    }

    func testConflictingRetryOfIncompleteClaimRequiresReconciliation() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let idempotencyKey = UUID()
        let original = try fixture.request(
            idempotencyKey: idempotencyKey,
            arguments: ["first"]
        )
        let conflicting = try fixture.request(
            idempotencyKey: idempotencyKey,
            arguments: ["second"]
        )
        _ = try fixture.journal.claim(
            installationID: installationID,
            request: original
        )

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: conflicting
            ),
            .indeterminate
        )
    }

    func testIdempotencyKeyRejectsDifferentRequestCommitment() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let idempotencyKey = UUID()
        let original = try fixture.request(
            idempotencyKey: idempotencyKey,
            arguments: ["first"]
        )
        let conflicting = try fixture.request(
            idempotencyKey: idempotencyKey,
            arguments: ["second"]
        )
        let claim = try fixture.journal.claim(
            installationID: installationID,
            request: original
        )
        try claim.complete(
            envelope: Self.envelope(
                for: SandboxGuestCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            )
        )

        XCTAssertThrowsError(
            try fixture.journal.replay(
                installationID: installationID,
                request: conflicting
            )
        ) { error in
            XCTAssertEqual(
                error as? SandboxRuntimeError,
                .unsupported(
                    "guest command idempotency key was already used for a different request"
                )
            )
        }
    }

    func testInstallationIdentityNamespacesIdempotencyKeys() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let request = try fixture.request()
        let firstInstallation = UUID()
        let secondInstallation = UUID()
        let claim = try fixture.journal.claim(
            installationID: firstInstallation,
            request: request
        )
        try claim.complete(
            envelope: Self.envelope(
                for: SandboxGuestCommandResult(
                    exitCode: 0,
                    standardOutput: Data("first".utf8),
                    standardError: Data()
                )
            )
        )

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: secondInstallation,
                request: request
            ),
            .unclaimed
        )
    }

    func testRequestCommitmentIsIndependentOfDictionaryOrder() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let key = UUID()
        let first = try fixture.request(
            idempotencyKey: key,
            environment: ["B": "2", "A": "1"]
        )
        let second = try fixture.request(
            idempotencyKey: key,
            environment: ["A": "1", "B": "2"]
        )

        XCTAssertEqual(
            try LumeGuestCommandJournal.commitment(for: first),
            try LumeGuestCommandJournal.commitment(for: second)
        )
    }

    func testResultPublicationNeverOverwritesDifferentOutcome() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let request = try fixture.request()
        let claim = try fixture.journal.claim(
            installationID: UUID(),
            request: request
        )
        let first = try Self.envelope(
            for: SandboxGuestCommandResult(
                exitCode: 0,
                standardOutput: Data("first".utf8),
                standardError: Data()
            )
        )
        try claim.complete(envelope: first)
        try claim.complete(envelope: first)

        XCTAssertThrowsError(
            try claim.complete(
                envelope: Self.envelope(
                    for: SandboxGuestCommandResult(
                        exitCode: 0,
                        standardOutput: Data("second".utf8),
                        standardError: Data()
                    )
                )
            )
        )
    }

    func testReplayTreatsSymbolicLinkResultAsIndeterminate() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let request = try fixture.request()
        _ = try fixture.journal.claim(
            installationID: installationID,
            request: request
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.commandDirectory(
                installationID: installationID,
                idempotencyKey: request.idempotencyKey
            ).appendingPathComponent(LumeGuestCommandJournal.resultFileName),
            withDestinationURL: URL(fileURLWithPath: "/dev/zero")
        )

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .indeterminate
        )
    }

    func testReplayTreatsNonPrivateCommandDirectoryAsIndeterminate() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let request = try fixture.request()
        _ = try fixture.journal.claim(
            installationID: installationID,
            request: request
        )
        let commandDirectory = fixture.commandDirectory(
            installationID: installationID,
            idempotencyKey: request.idempotencyKey
        )
        guard chmod(commandDirectory.path, 0o755) == 0 else {
            throw POSIXError(.EACCES)
        }

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .indeterminate
        )
    }

    func testReplayTreatsMalformedResultAsIndeterminate() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let request = try fixture.request()
        _ = try fixture.journal.claim(
            installationID: installationID,
            request: request
        )
        let resultFile = fixture.resultFile(
            installationID: installationID,
            idempotencyKey: request.idempotencyKey
        )
        try Data("not an envelope".utf8).write(to: resultFile)
        guard chmod(resultFile.path, 0o600) == 0 else {
            throw POSIXError(.EACCES)
        }

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .indeterminate
        )
    }

    func testReplayTreatsOversizedResultAsIndeterminate() throws {
        let fixture = try JournalFixture()
        defer { try? fixture.remove() }
        let installationID = UUID()
        let request = try fixture.request()
        _ = try fixture.journal.claim(
            installationID: installationID,
            request: request
        )
        let resultFile = fixture.resultFile(
            installationID: installationID,
            idempotencyKey: request.idempotencyKey
        )
        try Data(
            repeating: 0x41,
            count: LumeGuestCommandEnvelope.maximumEnvelopeBytes + 1
        ).write(to: resultFile)
        guard chmod(resultFile.path, 0o600) == 0 else {
            throw POSIXError(.EACCES)
        }

        XCTAssertEqual(
            try fixture.journal.replay(
                installationID: installationID,
                request: request
            ),
            .indeterminate
        )
    }

    private static func envelope(
        for result: SandboxGuestCommandResult
    ) throws -> Data {
        let envelope = TestEnvelope(
            magic: LumeGuestCommandEnvelope.magic,
            schemaVersion: LumeGuestCommandEnvelope.schemaVersion,
            exitCode: result.exitCode,
            standardOutputLength: result.standardOutput.count,
            standardErrorLength: result.standardError.count,
            standardOutputTruncated: result.standardOutputTruncated,
            standardErrorTruncated: result.standardErrorTruncated,
            timedOut: result.timedOut,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
}

private struct JournalFixture {
    let root: URL
    let storage: URL
    let journal: LumeGuestCommandJournal

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-command-journal-\(UUID().uuidString)",
            isDirectory: true
        )
        storage = root.appendingPathComponent("vms", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let workspace = LumeRuntimeWorkspace(storageDirectory: storage)
        try workspace.prepare()
        journal = LumeGuestCommandJournal(workspace: workspace)
    }

    func request(
        idempotencyKey: UUID = UUID(),
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> SandboxGuestCommandRequest {
        try SandboxGuestCommandRequest(
            idempotencyKey: idempotencyKey,
            executable: "/usr/bin/printf",
            arguments: arguments,
            environment: environment,
            workingDirectory: "/Users/lume",
            timeoutSeconds: 30
        )
    }

    func remove() throws {
        try FileManager.default.removeItem(at: root)
    }

    func commandDirectory(
        installationID: UUID,
        idempotencyKey: UUID
    ) -> URL {
        storage
            .appendingPathComponent(
                LumeRuntimeWorkspace.supportDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                LumeRuntimeWorkspace.commandJournalDirectoryName,
                isDirectory: true
            )
            .appendingPathComponent(
                installationID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent(
                LumeGuestCommandIdentity.identifier(for: idempotencyKey),
                isDirectory: true
            )
    }

    func resultFile(
        installationID: UUID,
        idempotencyKey: UUID
    ) -> URL {
        commandDirectory(
            installationID: installationID,
            idempotencyKey: idempotencyKey
        ).appendingPathComponent(LumeGuestCommandJournal.resultFileName)
    }
}

private struct TestEnvelope: Encodable {
    let magic: String
    let schemaVersion: UInt16
    let exitCode: Int32
    let standardOutputLength: Int
    let standardErrorLength: Int
    let standardOutputTruncated: Bool
    let standardErrorTruncated: Bool
    let timedOut: Bool
    let standardOutput: Data
    let standardError: Data

    private enum CodingKeys: String, CodingKey {
        case magic
        case schemaVersion = "schema_version"
        case exitCode = "exit_code"
        case standardOutputLength = "stdout_length"
        case standardErrorLength = "stderr_length"
        case standardOutputTruncated = "stdout_truncated"
        case standardErrorTruncated = "stderr_truncated"
        case timedOut = "timed_out"
        case standardOutput = "stdout_base64"
        case standardError = "stderr_base64"
    }
}
