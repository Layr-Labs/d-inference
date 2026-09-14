import Darwin
import Foundation
import SandboxCore
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class AccountlessBaseCandidateTests: XCTestCase, @unchecked Sendable {
    func testCreatesOnlyCandidateAndReplaysTheSameAttemptWithoutRestoringAgain() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        let first = try await prepare(f, runtime)
        XCTAssertFalse(first.installed); XCTAssertFalse(first.qualified); XCTAssertFalse(first.replayed)
        XCTAssertEqual(first.candidate.phase, .awaitingRootInstallation)
        XCTAssertEqual(first.candidate.source.kind, .appleRestore)
        let original = try Data(contentsOf: URL(fileURLWithPath: first.recordPath))
        let second = try await prepare(f, runtime)
        XCTAssertTrue(second.replayed); XCTAssertEqual(second.candidate, first.candidate)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.recordPath)), original)
        let restores = await runtime.restores
        XCTAssertEqual(restores, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(SandboxGuestTemplateReceipt.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.base.appendingPathComponent(".darkbloom-guest").path))
    }

    func testExistingOwnedBaseWithoutCandidateIsQuarantined() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        try await runtime.create(f.specification())
        await rejects { _ = try await self.prepare(f, runtime) }
        let restores = await runtime.restores
        XCTAssertEqual(restores, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.path))
    }

    func testUnownedBaseCannotBeAdoptedEvenWhenInjectedRuntimeClaimsStopped() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f, omitOwnership: true)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.path))
    }

    func testPartialLaterPhaseOrClaimedInstallationCannotResetAttempt() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        _ = try await prepare(f, runtime)
        let original = try Data(contentsOf: f.record)
        for (key, value) in [("phase", "bootstrapClaimed" as Any), ("schemaVersion", 2), ("installed", true), ("qualified", true)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object[key] = value
            let changed = try JSONSerialization.data(withJSONObject: object)
            try changed.write(to: f.record)
            await rejects { _ = try await self.prepare(f, runtime) }
            XCTAssertEqual(try Data(contentsOf: f.record), changed)
        }
        try Data("{".utf8).write(to: f.record)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertEqual(try Data(contentsOf: f.record), Data("{".utf8))
    }

    func testChangedReleaseOrSourceCannotMintAnotherAttempt() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        _ = try await prepare(f, runtime)
        let original = try Data(contentsOf: f.record)
        let manifest = f.baseFixture.releaseDirectory.appendingPathComponent("release-manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["version"] = "changed-host-release"
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertEqual(try Data(contentsOf: f.record), original)
        let owner = f.base.appendingPathComponent(".darkbloom-ownership.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: owner)) as? [String: Any])
        metadata["sourceReference"] = "/different.ipsw"
        try JSONSerialization.data(withJSONObject: metadata).write(to: owner)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertEqual(try Data(contentsOf: f.record), original)
    }

    func testBootDiskWriteIsDetectedWithoutHashingOrReadingItsContents() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        let first = try await prepare(f, runtime)
        let handle = try FileHandle(forWritingTo: f.disk)
        try handle.write(contentsOf: Data([1])); try handle.synchronize(); try handle.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: f.disk.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, first.candidate.disk.size)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertEqual(try JSONDecoder().decode(AccountlessBaseCandidateRecord.self, from: Data(contentsOf: f.record)), first.candidate)
    }

    func testUnsafeCandidateDiskOrPreparedArtifactsFailClosed() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        _ = try await prepare(f, runtime)
        let original = try Data(contentsOf: f.record)
        let moved = f.base.appendingPathComponent("original-candidate.json")
        try FileManager.default.moveItem(at: f.record, to: moved)
        try FileManager.default.createSymbolicLink(at: f.record, withDestinationURL: moved)
        await rejects { _ = try await self.prepare(f, runtime) }
        try FileManager.default.removeItem(at: f.record)
        try FileManager.default.moveItem(at: moved, to: f.record)
        let link = f.base.appendingPathComponent("linked-disk.img")
        XCTAssertEqual(Darwin.link(f.disk.path, link.path), 0)
        await rejects { _ = try await self.prepare(f, runtime) }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: f.base.appendingPathComponent(".darkbloom-guest"), withIntermediateDirectories: false)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertEqual(try Data(contentsOf: f.record), original)
    }

    func testPinnedStoreRefusesRenamedDirectoryAndDiskSymlinks() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        _ = try await prepare(f, runtime)
        let store = try AccountlessBaseCandidateStore(directory: f.base)
        let diskMoved = f.base.appendingPathComponent("original-disk.img")
        try FileManager.default.moveItem(at: f.disk, to: diskMoved)
        try FileManager.default.createSymbolicLink(at: f.disk, withDestinationURL: diskMoved)
        XCTAssertThrowsError(try store.diskIdentity(expectedBytes: 100 * SandboxResourcePolicy.gibibyte))
        let moved = f.baseFixture.storage.appendingPathComponent("base-original")
        try FileManager.default.moveItem(at: f.base, to: moved)
        try FileManager.default.createDirectory(at: f.base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try store.read())
    }

    func testRunningOrMismatchedRuntimeAndLegacySourceCannotCreateCandidate() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f, stateAfterCreate: .running)
        await rejects { _ = try await self.prepare(f, runtime) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.path))
        let other = try fixture(), wrongRuntime = CandidateRuntime(fixture: other)
        await rejects { _ = try await self.prepare(f, wrongRuntime) }
        let candidate = AccountlessBaseCandidatePreparer(runtime: wrongRuntime)
        await rejects { _ = try await candidate.prepare(specification: other.baseFixture.specification(),
            storage: other.baseFixture.storage, release: other.baseFixture.release()) }
        let restores = await wrongRuntime.restores
        XCTAssertEqual(restores, 0)
    }

    func testCancellationAfterRestoreRetainsUnclaimedImageAndDoesNotSilentlyRetry() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f, cancelAfterCreate: true)
        let task = Task { try await self.prepare(f, runtime) }
        await rejects { _ = try await task.value }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.disk.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.record.path))
        await rejects { _ = try await self.prepare(f, runtime) }
        let restores = await runtime.restores
        XCTAssertEqual(restores, 1)
    }

    func testPreparationLockContentionCannotReplaceCandidate() async throws {
        let f = try fixture(), runtime = CandidateRuntime(fixture: f)
        let first = try await prepare(f, runtime)
        let lock = try BaseGuestPreparationLock(directory: f.base)
        await rejects { _ = try await self.prepare(f, runtime) }
        withExtendedLifetime(lock) {}
        XCTAssertEqual(try JSONDecoder().decode(AccountlessBaseCandidateRecord.self, from: Data(contentsOf: f.record)), first.candidate)
    }

    private func prepare(_ f: CandidateFixture, _ runtime: CandidateRuntime) async throws -> AccountlessBaseCandidateReport {
        try await AccountlessBaseCandidatePreparer(runtime: runtime).prepare(specification: f.specification(),
            storage: f.baseFixture.storage, release: f.baseFixture.release())
    }
    private func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("operation should be rejected") } catch {}
    }
    private func fixture() throws -> CandidateFixture {
        let value = try CandidateFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: value.baseFixture.root) }
        return value
    }
}

private struct CandidateFixture: Sendable {
    let baseFixture: BaseGuestPreparationTestFixture
    var base: URL { baseFixture.storage.appendingPathComponent("base") }
    var disk: URL { base.appendingPathComponent("disk.img") }
    var record: URL { base.appendingPathComponent(AccountlessBaseCandidateRecord.fileName) }
    init() throws {
        baseFixture = try BaseGuestPreparationTestFixture()
        try FileManager.default.removeItem(at: base)
    }
    func specification() throws -> SandboxVirtualMachineSpecification {
        try .init(name: "base", resources: .macOSSmall(), imageSource: .appleRestore(url: URL(fileURLWithPath: "/image.ipsw")),
            diskBytes: 100 * SandboxResourcePolicy.gibibyte)
    }
}

private actor CandidateRuntime: AccountlessBaseCandidateRuntime {
    let fixture: CandidateFixture
    let omitOwnership: Bool
    let stateAfterCreate: SandboxVirtualMachineState
    let cancelAfterCreate: Bool
    var restores = 0
    init(fixture: CandidateFixture, omitOwnership: Bool = false, stateAfterCreate: SandboxVirtualMachineState = .stopped,
         cancelAfterCreate: Bool = false) {
        self.fixture = fixture; self.omitOwnership = omitOwnership; self.stateAfterCreate = stateAfterCreate
        self.cancelAfterCreate = cancelAfterCreate
    }
    func requireBaseCandidateStorage(_ storage: URL) throws {
        guard storage == fixture.baseFixture.storage else { throw AccountlessBaseCandidateError.candidateChanged }
    }
    func create(_ specification: SandboxVirtualMachineSpecification) throws {
        if restores > 0 { return }
        restores += 1
        try FileManager.default.createDirectory(at: fixture.base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if !omitOwnership { try fixture.baseFixture.writeOwnership(id: fixture.baseFixture.installationID, sourceKind: "apple_restore") }
        let disk = open(fixture.disk.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard disk >= 0 else { throw POSIXError(.EIO) }
        defer { close(disk) }
        // Sparse file: no VM and no guest content or 100GiB disk allocation.
        guard ftruncate(disk, off_t(specification.diskBytes)) == 0 else { throw POSIXError(.EIO) }
        if cancelAfterCreate { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func inspect(name: String) -> SandboxVirtualMachineRecord? {
        guard restores > 0 else { return nil }
        return .init(name: name, state: stateAfterCreate, cpuCount: 4,
            memoryBytes: 8 * SandboxResourcePolicy.gibibyte, diskBytes: 100 * SandboxResourcePolicy.gibibyte)
    }
}
