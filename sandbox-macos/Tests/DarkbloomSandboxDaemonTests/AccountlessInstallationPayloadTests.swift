import Darwin
import Foundation
import SandboxRuntime
import Security
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessInstallationPayloadTests: XCTestCase, @unchecked Sendable {
    func testMaterializesOnlyBoundGuestPayloadAndJobWithoutExecution() async throws {
        let f = try fixture()
        let plan = try await f.producer.prepare(candidate: f.candidate, release: f.release, destination: f.destination)
        XCTAssertEqual(plan.binding.candidateID, f.candidate.candidateID)
        XCTAssertEqual(plan.binding.bootstrapAttemptID, f.candidate.bootstrapAttemptID)
        XCTAssertEqual(plan.maximumBootSeconds, 300)
        XCTAssertEqual(plan.files.count, 10)
        let stage = f.destination.appendingPathComponent("data-overlay" + plan.guestStagePath)
        let binding = try Data(contentsOf: stage.appendingPathComponent("installation-binding.json"))
        XCTAssertFalse(binding.isEmpty)
        XCTAssertEqual(BaseGuestRelease.digest(binding), plan.bindingSHA256)
        for (relative, expected) in plan.files {
            XCTAssertFalse(relative.contains("..")); XCTAssertFalse(relative.hasPrefix("/"))
            let path = f.destination.appendingPathComponent("data-overlay/" + relative)
            XCTAssertEqual(BaseGuestRelease.digest(try Data(contentsOf: path)), expected)
        }
        let job = try XCTUnwrap(PropertyListSerialization.propertyList(from:
            Data(contentsOf: f.destination.appendingPathComponent("data-overlay" + plan.guestLaunchDaemonPath)), format: nil) as? [String: Any])
        XCTAssertEqual(job["UserName"] as? String, "root")
        XCTAssertEqual(job["KeepAlive"] as? Bool, false)
        XCTAssertEqual(job["ProgramArguments"] as? [String], ["/bin/zsh", "-f", plan.guestStagePath + "/first-boot.zsh",
            f.candidate.bootstrapAttemptID.uuidString.lowercased(), plan.bindingSHA256])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.appendingPathComponent("result").path))
        XCTAssertFalse(plan.files.keys.contains { $0.contains("broker.json") || $0.contains("control.cdr") || $0.contains("workspace.cdr") })
        let syntax = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-n", stage.appendingPathComponent("first-boot.zsh").path], timeoutSeconds: 10)
        XCTAssertEqual(syntax.exitCode, 0, String(decoding: syntax.standardError, as: UTF8.self))
        let again = try JSONDecoder().decode(AccountlessInstallationPayloadPlan.self,
            from: Data(contentsOf: f.destination.appendingPathComponent("plan.json")))
        XCTAssertEqual(again, plan)
    }

    func testExistingDestinationAndInvalidReleaseDoNotOverwrite() async throws {
        let f = try fixture()
        let insideRelease = f.release.directory.appendingPathComponent("must-not-create")
        await rejects { _ = try await f.producer.prepare(candidate: f.candidate, release: f.release, destination: insideRelease) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: insideRelease.path))
        let plan = try await f.producer.prepare(candidate: f.candidate, release: f.release, destination: f.destination)
        let original = try Data(contentsOf: f.destination.appendingPathComponent("plan.json"))
        await rejects { _ = try await f.producer.prepare(candidate: f.candidate, release: f.release, destination: f.destination) }
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("plan.json")), original)
        XCTAssertEqual(plan.binding.bootstrapAttemptID, f.candidate.bootstrapAttemptID)
        let invalid = try fixture()
        try Data("unexpected".utf8).write(to: invalid.release.directory.appendingPathComponent("guest/extra"))
        await rejects { _ = try await invalid.producer.prepare(candidate: invalid.candidate, release: invalid.release, destination: invalid.destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.destination.path))
        let symlink = invalid.base.root.resolvingSymlinksInPath().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: f.destination)
        await rejects { _ = try await f.producer.prepare(candidate: f.candidate, release: f.release, destination: symlink) }
        XCTAssertEqual(try Data(contentsOf: f.destination.appendingPathComponent("plan.json")), original)
    }

    func testSourceMutationAfterCopyCannotPublishPlan() async throws {
        let f = try fixture(), counter = AccountlessCopyCounter()
        let producer = AccountlessInstallationPayload(loadRelease: { directory in
            let current = try BaseGuestRelease(directory: directory, verifySignature: { _, _ in })
            if directory == f.release.directory, counter.next() == 2 {
                try Data("changed after copy".utf8).write(to: directory.appendingPathComponent("guest/install-sandbox-guest.sh"))
            }
            return current
        })
        await rejects { _ = try await producer.prepare(candidate: f.candidate, release: f.release, destination: f.destination) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.appendingPathComponent("plan.json").path))
    }

    func testCopyPreservesRealAdHocSigningExtendedAttributes() async throws {
        let f = try fixture()
        for (relative, identifier) in [("release-manifest.json", "io.darkbloom.sandbox.release-manifest"),
                                        ("guest/darkbloom-sandbox-guest", "io.darkbloom.sandbox.guest")] {
            let result = try await SandboxProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--force", "--sign", "-", "--identifier", identifier, f.release.directory.appendingPathComponent(relative).path], timeoutSeconds: 10)
            XCTAssertEqual(result.exitCode, 0, String(decoding: result.standardError, as: UTF8.self))
        }
        // Only this test dependency accepts ad-hoc identity; production loading
        // keeps BaseGuestRelease's exact Developer ID requirement.
        let producer = AccountlessInstallationPayload(loadRelease: { directory in
            try BaseGuestRelease(directory: directory, verifySignature: { path, identifier in
                var code: SecStaticCode?, requirement: SecRequirement?
                guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
                      SecRequirementCreateWithString("identifier \"\(identifier)\"" as CFString, [], &requirement) == errSecSuccess,
                      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                    throw BaseGuestPreparationError.invalidRelease
                }
            })
        })
        let plan = try await producer.prepare(candidate: f.candidate, release: f.release, destination: f.destination)
        XCTAssertEqual(plan.binding.payload, f.candidate.payload)
    }

    func testPayloadInventoryRejectsUnexpectedOrChangedOutput() throws {
        let f = try fixture(), output = try AccountlessInstallationPayloadFiles(destination: f.destination)
        let directory = try output.createDirectory("data-overlay/known")
        try output.write(Data("safe".utf8), to: directory.appendingPathComponent("one"), mode: 0o400)
        XCTAssertEqual(try output.inventory().count, 1)
        let extra = directory.appendingPathComponent("unexpected")
        try Data("unknown".utf8).write(to: extra)
        XCTAssertThrowsError(try output.inventory())
        try FileManager.default.removeItem(at: extra)
        let expected = directory.appendingPathComponent("one")
        XCTAssertEqual(chmod(expected.path, 0o600), 0)
        try Data("changed".utf8).write(to: expected)
        XCTAssertThrowsError(try output.inventory())
    }

    private func fixture() throws -> AccountlessInstallationTestFixture {
        let f = try AccountlessInstallationTestFixture(); addTeardownBlock { f.remove() }; return f
    }
    private func rejects(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("invalid materialization was accepted") } catch {}
    }
}

private final class AccountlessCopyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
