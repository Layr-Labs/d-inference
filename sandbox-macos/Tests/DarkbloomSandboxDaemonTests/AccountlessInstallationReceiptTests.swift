import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessInstallationReceiptTests: XCTestCase, @unchecked Sendable {
    func testRealWriterPreservesPartialObservationsAndProducesSchema2Completion() async throws {
        let f = try fixture()
        let binding = try AccountlessInstallationBinding(candidate: f.candidate, release: f.release)
        let bindingPath = f.base.root.appendingPathComponent("binding.json")
        try JSONEncoder().encode(binding).write(to: bindingPath)
        let bindingBytes = try Data(contentsOf: bindingPath)
        let directory = f.base.root.appendingPathComponent("result")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let receipt = directory.appendingPathComponent("receipt.json")
        var process = try await write(receipt, binding: bindingPath)
        XCTAssertEqual(process.exitCode, 0, String(decoding: process.standardError, as: UTF8.self))
        var record = try decode(receipt)
        try record.validate(candidate: f.candidate)
        XCTAssertNil(record.installation); XCTAssertNil(record.guestArchitecture); XCTAssertNil(record.shellExitCode)
        XCTAssertThrowsError(try record.completedInstallation(candidate: f.candidate))
        let partial = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        XCTAssertNil(partial["installation"]); XCTAssertNil(partial["virtualizedRootObserved"])
        process = try await write(receipt, binding: bindingPath, stage: "complete", values: success)
        XCTAssertEqual(process.exitCode, 0, String(decoding: process.standardError, as: UTF8.self))
        record = try decode(receipt)
        let installation = try record.completedInstallation(candidate: f.candidate)
        XCTAssertEqual(installation.schemaVersion, 2); XCTAssertTrue(installation.installationComplete)
        XCTAssertEqual(installation.rootJobID, f.candidate.bootstrapAttemptID)
        XCTAssertEqual(installation.guestOperatingSystemVersion, "26.0.1")
        XCTAssertEqual(installation.guestArchitecture, "arm64")
        var metadata = stat(); XCTAssertEqual(lstat(receipt.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600); XCTAssertEqual(metadata.st_nlink, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["receipt.json"])
        let complete = try Data(contentsOf: receipt)
        XCTAssertFalse(String(decoding: complete, as: UTF8.self).contains("bootstrapRetired"))
        XCTAssertEqual(try Data(contentsOf: bindingPath), bindingBytes, "plutil reads must not rewrite the immutable binding")
    }

    func testFailureKeepsKnownFactsOmitsUnknownAndCannotBecomeSuccess() async throws {
        let f = try fixture(), paths = try writerPaths(f)
        let values = ["26.0.1", "arm64", "true", "true", "70", "unknown", "unknown", "unknown", "70"]
        let result = try await write(paths.receipt, binding: paths.binding, stage: "failed", error: "installerFailed", values: values)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
        let record = try decode(paths.receipt)
        try record.validate(candidate: f.candidate)
        XCTAssertEqual(record.installation?.installerExitCode, 70)
        XCTAssertNil(record.installation?.installedPayloadVerified)
        XCTAssertNil(record.installation?.bootstrapAccountAbsent)
        XCTAssertThrowsError(try record.completedInstallation(candidate: f.candidate))
        let original = try Data(contentsOf: paths.receipt)
        let retry = try await write(paths.receipt, binding: paths.binding, stage: "complete", values: success)
        XCTAssertNotEqual(retry.exitCode, 0); XCTAssertEqual(try Data(contentsOf: paths.receipt), original)
    }

    func testForeignBindingSymlinkAndIncompleteSuccessCannotOverwriteReceipt() async throws {
        let f = try fixture(), paths = try writerPaths(f)
        let first = try await write(paths.receipt, binding: paths.binding)
        XCTAssertEqual(first.exitCode, 0)
        let original = try Data(contentsOf: paths.receipt)
        var binding = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.binding)) as? [String: Any])
        binding["candidateID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: binding).write(to: paths.binding)
        let conflict = try await write(paths.receipt, binding: paths.binding, stage: "complete", values: success)
        XCTAssertNotEqual(conflict.exitCode, 0); XCTAssertEqual(try Data(contentsOf: paths.receipt), original)
        try FileManager.default.removeItem(at: paths.receipt)
        let victim = f.base.root.appendingPathComponent("victim")
        try original.write(to: victim)
        try FileManager.default.createSymbolicLink(at: paths.receipt, withDestinationURL: victim)
        let linked = try await write(paths.receipt, binding: paths.binding)
        XCTAssertNotEqual(linked.exitCode, 0); XCTAssertEqual(try Data(contentsOf: victim), original)
        try FileManager.default.removeItem(at: paths.receipt)
        let invalid = try await write(paths.receipt, binding: paths.binding, stage: "complete")
        XCTAssertNotEqual(invalid.exitCode, 0); XCTAssertFalse(FileManager.default.fileExists(atPath: paths.receipt.path))
    }

    func testRealWriterFailureLeavesPriorCompleteJSONUntouched() async throws {
        let f = try fixture(), paths = try writerPaths(f)
        let initial = try await write(paths.receipt, binding: paths.binding)
        XCTAssertEqual(initial.exitCode, 0)
        let original = try Data(contentsOf: paths.receipt)
        let failed = try await write(paths.receipt, binding: paths.binding, stage: "complete", values: success, limitFileSize: true)
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertEqual(try Data(contentsOf: paths.receipt), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.receipt.deletingLastPathComponent().path), ["receipt.json"])
    }

    func testCompleteReceiptStillRequiresExactCandidateAndDoesNotClaimReadiness() async throws {
        let f = try fixture(), other = try fixture(), paths = try writerPaths(f)
        let written = try await write(paths.receipt, binding: paths.binding, stage: "complete", values: success)
        XCTAssertEqual(written.exitCode, 0)
        let record = try decode(paths.receipt)
        XCTAssertThrowsError(try record.completedInstallation(candidate: other.candidate))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.receipt)) as? [String: Any])
        XCTAssertNil(object["ready"]); XCTAssertNil(object["qualified"])
    }

    func testShutdownFailureRetainsInstallationFactsButCannotCompleteOverallAttempt() async throws {
        let f = try fixture(), paths = try writerPaths(f)
        let complete = try await write(paths.receipt, binding: paths.binding, stage: "complete", values: success)
        XCTAssertEqual(complete.exitCode, 0)
        var failedValues = success; failedValues[8] = "70"
        let failure = try await write(paths.receipt, binding: paths.binding, stage: "failed", error: "shutdownFailed", values: failedValues)
        XCTAssertEqual(failure.exitCode, 0, String(decoding: failure.standardError, as: UTF8.self))
        let record = try decode(paths.receipt)
        try record.validate(candidate: f.candidate)
        XCTAssertTrue(record.installation?.installationComplete == true)
        XCTAssertThrowsError(try record.completedInstallation(candidate: f.candidate))
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.receipt)) as? [String: Any])
        value["error"] = "installerFailed"
        let contradictory = try JSONDecoder().decode(AccountlessInstallationResult.self,
            from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try contradictory.validate(candidate: f.candidate))
    }

    func testSourceReferenceIsEscapedAsDataAndBindingIsUnchanged() async throws {
        let f = try fixture(), paths = try writerPaths(f)
        let marker = f.base.root.appendingPathComponent("must-not-execute")
        let source = SandboxGuestBaseSource(name: f.candidate.source.name,
            installationID: f.candidate.source.installationID, kind: .appleRestore,
            reference: "/image \"quoted\" & <tag> $(touch \(marker.path)) \\tail",
            ownershipSHA256: f.candidate.source.ownershipSHA256)
        let candidate = AccountlessBaseCandidateRecord(schemaVersion: 1, phase: .awaitingRootInstallation,
            candidateID: f.candidate.candidateID, bootstrapAttemptID: f.candidate.bootstrapAttemptID,
            source: source, payload: f.candidate.payload, resources: f.candidate.resources,
            disk: f.candidate.disk, installed: false, qualified: false)
        let binding = try JSONEncoder().encode(AccountlessInstallationBinding(candidate: candidate, release: f.release))
        try binding.write(to: paths.binding)
        let result = try await write(paths.receipt, binding: paths.binding, stage: "complete", values: success)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
        let receipt = try decode(paths.receipt).completedInstallation(candidate: candidate)
        XCTAssertEqual(receipt.source.reference, source.reference)
        XCTAssertEqual(try Data(contentsOf: paths.binding), binding)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private var success: [String] { ["26.0.1", "arm64", "true", "true", "0", "true", "true", "true", "0"] }
    private func fixture() throws -> AccountlessInstallationTestFixture {
        let f = try AccountlessInstallationTestFixture(); addTeardownBlock { f.remove() }; return f
    }
    private func writerPaths(_ f: AccountlessInstallationTestFixture) throws -> (binding: URL, receipt: URL) {
        let binding = f.base.root.appendingPathComponent("binding.json"), directory = f.base.root.appendingPathComponent("result")
        try JSONEncoder().encode(AccountlessInstallationBinding(candidate: f.candidate, release: f.release)).write(to: binding)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (binding, directory.appendingPathComponent("receipt.json"))
    }
    private func decode(_ path: URL) throws -> AccountlessInstallationResult {
        try JSONDecoder().decode(AccountlessInstallationResult.self, from: Data(contentsOf: path))
    }
    private func write(_ path: URL, binding: URL, stage: String = "rootJobStarted", error: String = "none",
                       values: [String] = Array(repeating: "unknown", count: 9), limitFileSize: Bool = false) async throws -> SandboxProcessResult {
        try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-f", "-c", (limitFileSize ? "ulimit -f 1\n" : "") + AccountlessInstallationReceiptWriter.shellFunction +
                "\nwrite_accountless_receipt \"$@\"", "accountless-receipt-test", path.path, binding.path, stage, error] + values,
            timeoutSeconds: 15, maximumOutputBytes: 32 * 1024)
    }
}
