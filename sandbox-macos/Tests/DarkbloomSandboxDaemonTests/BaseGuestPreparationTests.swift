import CryptoKit
import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class BaseGuestPreparationTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> Fixture {
        let fixture = try Fixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.root) }
        return fixture
    }

    func testReleaseRejectsChangedPayloadAdditionalEntryAndInvalidSignature() throws {
        let f = try fixture()
        XCTAssertNoThrow(try f.release())
        XCTAssertThrowsError(try BaseGuestRelease(directory: f.releaseDirectory, verifySignature: { _, _ in
            throw BaseGuestPreparationError.invalidRelease
        }))
        let executable = f.releaseDirectory.appendingPathComponent("guest/darkbloom-sandbox-guest")
        try Data("modified".utf8).write(to: executable)
        XCTAssertThrowsError(try f.release())
        let second = try fixture()
        try Data().write(to: second.releaseDirectory.appendingPathComponent("guest/unexpected"))
        XCTAssertThrowsError(try second.release())
    }

    func testProductionSignatureValidationWhenReleaseProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["DARKBLOOM_SANDBOX_TEST_GUEST_RELEASE"] else {
            throw XCTSkip("Set DARKBLOOM_SANDBOX_TEST_GUEST_RELEASE to validate a real signed package")
        }
        let release = try BaseGuestRelease(directory: URL(fileURLWithPath: path))
        XCTAssertEqual(release.hashes.count, 4)
    }

    func testBootstrapUsesFixedShellAndPositionalArgumentsWithinCommandBounds() throws {
        let f = try fixture(), release = try f.release(), staging = try release.stage(in: f.storage)
        let request = try BaseGuestInstallation.request(staging: staging, release: release)
        XCTAssertEqual(request.executable, "/bin/zsh")
        XCTAssertEqual(Array(request.arguments.prefix(4)), ["-f", "-c", BaseGuestInstallation.rootInvocation, "darkbloom-bootstrap-auth"])
        XCTAssertEqual(request.arguments[4], BaseGuestInstallation.script)
        XCTAssertTrue(BaseGuestInstallation.rootInvocation.contains("kern.hv_vmm_present"))
        XCTAssertTrue(BaseGuestInstallation.rootInvocation.contains("$(/usr/bin/id -un) == lume"))
        XCTAssertTrue(BaseGuestInstallation.rootInvocation.contains("/usr/bin/sudo -S -p ''"))
        XCTAssertFalse(request.arguments[4].contains(f.releaseDirectory.path))
        XCTAssertEqual(request.timeoutSeconds, 300)
        XCTAssertLessThan(request.arguments.reduce(0) { $0 + $1.utf8.count }, 65536)
        try staging.removeAfterStopped()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
    }

    func testInstallsThenPublishesStoppedTemplateAndReplaysWithoutAnotherExecution() async throws {
        let f = try fixture(), release = try f.release()
        let runtime = FakeBaseGuestVM(result: try JSONEncoder().encode(f.receipt(release: release)))
        let staging = try release.stage(in: f.storage)
        let preparer = BaseGuestPreparer(runtime: runtime)
        _ = try await preparer.prepare(specification: f.specification(), storage: f.storage,
                                      release: release, staging: staging)
        let store = BaseGuestTemplateStore(directory: f.storage.appendingPathComponent("base"))
        let record = try XCTUnwrap(store.matching(name: "base", release: release))
        XCTAssertTrue(record.bootstrapRetired && record.stoppedVerified)
        XCTAssertEqual(record.installationID, f.installationID)
        let events = await runtime.events
        XCTAssertEqual(events.filter { ["start", "execute", "stop"].contains($0) }, ["start", "execute", "stop"])
        let again = try release.stage(in: f.storage)
        _ = try await preparer.prepare(specification: f.specification(), storage: f.storage,
                                      release: release, staging: again)
        let repeatedEvents = await runtime.events
        XCTAssertEqual(repeatedEvents.filter { $0 == "execute" }.count, 1)
    }

    func testInvalidGuestProofStopsVMAndCannotPublishTemplate() async throws {
        let f = try fixture(), release = try f.release(), staging = try release.stage(in: f.storage)
        let runtime = FakeBaseGuestVM(result: Data("{}".utf8))
        do {
            _ = try await BaseGuestPreparer(runtime: runtime).prepare(specification: f.specification(),
                storage: f.storage, release: release, staging: staging)
            XCTFail("invalid proof must not publish a template")
        } catch {}
        let events = await runtime.events
        XCTAssertEqual(events.filter { $0 == "stop" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.appendingPathComponent("base/.darkbloom-template.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.directory.path))
    }

    func testStoredTemplateRejectsChangedOwnership() async throws {
        let f = try fixture(), release = try f.release()
        let store = BaseGuestTemplateStore(directory: f.storage.appendingPathComponent("base"))
        try store.publish(SandboxGuestTemplateReceipt(name: "base", installationID: f.installationID,
            release: release, receipt: f.receipt(release: release)))
        try f.writeOwnership(id: UUID())
        XCTAssertThrowsError(try store.matching(name: "base", release: release))
    }

    func testHostOnlyUpgradeReplaysPreparationAndPreservesOriginalProvenance() async throws {
        let f = try fixture(), original = try f.release()
        let runtime = FakeBaseGuestVM(result: try JSONEncoder().encode(f.receipt(release: original)))
        let preparer = BaseGuestPreparer(runtime: runtime)
        _ = try await preparer.prepare(specification: f.specification(), storage: f.storage,
            release: original, staging: original.stage(in: f.storage))
        let manifest = f.releaseDirectory.appendingPathComponent("release-manifest.json")
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        value["version"] = "host-only-upgrade"
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        let upgraded = try f.release()
        XCTAssertNotEqual(upgraded.manifestSHA256, original.manifestSHA256)
        _ = try await preparer.prepare(specification: f.specification(), storage: f.storage,
            release: upgraded, staging: upgraded.stage(in: f.storage))
        let events = await runtime.events
        XCTAssertEqual(events.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "execute" }.count, 1)
        let store = BaseGuestTemplateStore(directory: f.storage.appendingPathComponent("base"))
        let retained = try XCTUnwrap(store.matching(name: "base", release: upgraded))
        XCTAssertEqual(retained.releaseManifestSHA256, original.manifestSHA256)
    }

    func testChangedGuestPayloadCannotReuseStoredTemplate() throws {
        for name in BaseGuestRelease.files {
            let f = try fixture(), original = try f.release()
            let store = BaseGuestTemplateStore(directory: f.storage.appendingPathComponent("base"))
            try store.publish(SandboxGuestTemplateReceipt(name: "base", installationID: f.installationID,
                release: original, receipt: f.receipt(release: original)))
            let changed = Data("new guest payload".utf8)
            try changed.write(to: f.releaseDirectory.appendingPathComponent("guest/" + name))
            let manifest = f.releaseDirectory.appendingPathComponent("release-manifest.json")
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            var files = try XCTUnwrap(value["files"] as? [String: String])
            files["guest/" + name] = BaseGuestRelease.digest(changed)
            value["files"] = files
            try JSONSerialization.data(withJSONObject: value).write(to: manifest)
            XCTAssertThrowsError(try store.matching(name: "base", release: f.release()), name)
        }
    }

    func testConcurrentPreparationCannotAcquireTheSameBase() throws {
        let f = try fixture(), directory = f.storage.appendingPathComponent("base")
        var first: BaseGuestPreparationLock? = try BaseGuestPreparationLock(directory: directory)
        XCTAssertThrowsError(try BaseGuestPreparationLock(directory: directory))
        withExtendedLifetime(first) {}
        first = nil
        XCTAssertNoThrow(try BaseGuestPreparationLock(directory: directory))
    }

    func testStopFailureCannotPublishReadyTemplate() async throws {
        let f = try fixture(), release = try f.release(), staging = try release.stage(in: f.storage)
        let runtime = FakeBaseGuestVM(result: try JSONEncoder().encode(f.receipt(release: release)), stopFails: true)
        do {
            _ = try await BaseGuestPreparer(runtime: runtime).prepare(specification: f.specification(),
                storage: f.storage, release: release, staging: staging)
            XCTFail("unproven stop must prevent template publication")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.storage.appendingPathComponent("base/.darkbloom-template.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.directory.path))
    }

    private typealias Fixture = BaseGuestPreparationTestFixture
}

private actor FakeBaseGuestVM: BaseGuestVirtualMachine {
    let result: Data
    let stopFails: Bool
    var events: [String] = []
    var state = SandboxVirtualMachineState.stopped
    init(result: Data, stopFails: Bool = false) { self.result = result; self.stopFails = stopFails }
    func capabilities() -> SandboxRuntimeCapabilities {
        SandboxRuntimeCapabilities(runtime: "lume", version: "0.5.3", supportsMacOS: true, supportsPause: false, supportsSnapshots: false)
    }
    func create(_ specification: SandboxVirtualMachineSpecification) { events.append("create") }
    func start(name: String) { events.append("start"); state = .running }
    func stop(name: String) throws {
        events.append("stop")
        guard !stopFails else { throw BaseGuestPreparationError.unsafeTemplate }
        state = .stopped
    }
    func inspect(name: String) -> SandboxVirtualMachineRecord? {
        SandboxVirtualMachineRecord(name: name, state: state, cpuCount: 4, memoryBytes: 8 * 1_073_741_824, diskBytes: 100 * 1_073_741_824)
    }
    func execute(name: String, request: SandboxGuestCommandRequest) -> SandboxGuestCommandResult {
        events.append("execute")
        return SandboxGuestCommandResult(exitCode: 0, standardOutput: result, standardError: Data())
    }
}
