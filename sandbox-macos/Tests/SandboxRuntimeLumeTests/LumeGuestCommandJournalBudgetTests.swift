import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeGuestCommandJournalBudgetTests: XCTestCase, @unchecked Sendable {
    func testWorstCaseSerializedResultsFitReservedOverheadWithControlAndSafety() throws {
        let result = SandboxGuestCommandResult(exitCode: 255,
            standardOutput: Data(repeating: 0xff, count: LumeGuestCommandEnvelope.maximumStreamBytes),
            standardError: Data(repeating: 0xff, count: LumeGuestCommandEnvelope.maximumStreamBytes),
            standardOutputTruncated: false, standardErrorTruncated: false)
        let envelope = try LumeGuestCommandResultDecoder.encode(result)
        XCTAssertGreaterThan(envelope.count, 2 * LumeGuestCommandEnvelope.maximumStreamBytes)
        XCTAssertLessThanOrEqual(envelope.count, LumeGuestCommandEnvelope.maximumEnvelopeBytes)
        XCTAssertEqual(try LumeGuestCommandResultDecoder.decode(envelope), result)
        XCTAssertEqual(LumeGuestCommandJournalBudget.maximumCommandCount, 256)
        let accounted = UInt64(LumeGuestCommandJournalBudget.maximumCommandCount)
            * LumeGuestCommandJournalBudget.maximumCommandStorageBytes
            + LumeGuestCommandJournalBudget.controlDiskBytes + LumeGuestCommandJournalBudget.safetyBytes
        XCTAssertLessThanOrEqual(accounted, SandboxStorageReservation.perSandboxOverheadBytes)
    }

    func testLastAcceptedIDAndEarlierResultsSurviveRestartWhileNextIDIsDenied() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var accepted: [(SandboxGuestCommandRequest, SandboxGuestCommandResult)] = []
        for index in 0..<LumeGuestCommandJournalBudget.maximumCommandCount {
            let request = try fixture.request()
            let result = SandboxGuestCommandResult(exitCode: 0,
                standardOutput: Data("accepted-\(index)".utf8), standardError: Data())
            let claim = try fixture.journal().claim(installationID: fixture.installationID, request: request)
            try claim.complete(envelope: LumeGuestCommandResultDecoder.encode(result))
            accepted.append((request, result))
        }
        let restarted = fixture.journal(), rejected = try fixture.request()
        XCTAssertThrowsError(try restarted.claim(installationID: fixture.installationID, request: rejected)) {
            XCTAssertEqual($0 as? SandboxRuntimeError, .commandLimitReached)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commandDirectory(rejected).path))
        XCTAssertEqual(restarted.replay(installationID: fixture.installationID, request: rejected), .unclaimed)
        for (request, result) in accepted {
            XCTAssertEqual(restarted.replay(installationID: fixture.installationID, request: request), .completed(result))
        }
    }

    func testOversizedLegacyJournalPreservesReplaysAndIncompleteClaimsWithoutNewAdmission() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let historical = try fixture.request(), incomplete = try fixture.request()
        let result = SandboxGuestCommandResult(exitCode: 0, standardOutput: Data("old result".utf8), standardError: Data())
        let claim = try fixture.journal().claim(installationID: fixture.installationID, request: historical)
        try claim.complete(envelope: LumeGuestCommandResultDecoder.encode(result))
        _ = try fixture.journal().claim(installationID: fixture.installationID, request: incomplete)
        try fixture.fillIncompleteDirectories(count: 300)
        let restarted = fixture.journal(), rejected = try fixture.request()
        XCTAssertThrowsError(try restarted.claim(installationID: fixture.installationID, request: rejected)) {
            XCTAssertEqual($0 as? SandboxRuntimeError, .commandLimitReached)
        }
        XCTAssertEqual(restarted.replay(installationID: fixture.installationID, request: historical), .completed(result))
        XCTAssertEqual(restarted.replay(installationID: fixture.installationID, request: incomplete), .indeterminate)
        let conflict = try SandboxGuestCommandRequest(idempotencyKey: historical.idempotencyKey,
            executable: "/usr/bin/false")
        XCTAssertEqual(restarted.replay(installationID: fixture.installationID, request: conflict), .conflictingCompleted(result))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.commandDirectory(rejected).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.installation.path).count, 302)
    }

    func testLimitDenialDoesNotLaunchOrStopGuestAndHistoricalRuntimeReplayStillWorks() async throws {
        let fixture = try FakeLumeFixture(initialState: "running")
        defer { try? fixture.remove() }
        let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let capacity = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try capacity.reserve(sandboxID: SandboxID(), generation: SandboxGeneration(rawValue: 1)!,
            virtualMachineName: fixture.virtualMachineName, resources: SandboxResourceSpecification.macOSSmall(),
            expiresAt: clock.now().addingTimeInterval(60))
        try fixture.bindOwnership(to: lease.scope)
        let identity = try LumeVirtualMachineOwnership.requireOwned(name: fixture.virtualMachineName,
            owner: .init(operationScope: lease.scope), in: fixture.storage)
        let workspace = LumeRuntimeWorkspace(storageDirectory: fixture.storage)
        let journal = LumeGuestCommandJournal(workspace: workspace)
        let historical = try SandboxGuestCommandRequest(idempotencyKey: UUID(), executable: "/usr/bin/true")
        let result = SandboxGuestCommandResult(exitCode: 0, standardOutput: Data("historical".utf8), standardError: Data())
        let claim = try journal.claim(installationID: identity.installationID, request: historical)
        try claim.complete(envelope: LumeGuestCommandResultDecoder.encode(result))
        let installation = workspace.commandJournalDirectory.appendingPathComponent(identity.installationID.uuidString.lowercased())
        for _ in 1..<LumeGuestCommandJournalBudget.maximumCommandCount {
            try FileManager.default.createDirectory(at: installation.appendingPathComponent(UUID().uuidString.lowercased()),
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let runtime = try fixture.makeLeaseFencedRuntime(capacityArbiter: capacity,
            guestCommandPolicy: .baseImagePreparationAndDevelopment)
        do {
            _ = try await runtime.execute(scope: lease.scope, name: fixture.virtualMachineName,
                request: SandboxGuestCommandRequest(idempotencyKey: UUID(), executable: "/usr/bin/true"))
            XCTFail("full journal must deny new commands")
        } catch let error as SandboxRuntimeError { XCTAssertEqual(error, .commandLimitReached) }
        let replay = try await runtime.execute(scope: lease.scope, name: fixture.virtualMachineName, request: historical)
        XCTAssertEqual(replay, result)
        let record = try await runtime.inspect(scope: lease.scope, name: fixture.virtualMachineName)
        XCTAssertEqual(record?.state, .running)
        XCTAssertEqual(try capacity.snapshot().leases, [lease])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.guestCommandStarted.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("stop-invoked").path))
    }

    private struct Fixture {
        let root: URL
        let vm: URL
        let workspace: LumeRuntimeWorkspace
        let installationID = UUID()
        var installation: URL { vm.appendingPathComponent(".darkbloom-command-journal").appendingPathComponent(installationID.uuidString.lowercased()) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-budget-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            vm = root.appendingPathComponent("vm")
            try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workspace = LumeRuntimeWorkspace(storageDirectory: root)
        }
        func journal() -> LumeGuestCommandJournal { LumeGuestCommandJournal(workspace: workspace, ownedVirtualMachineDirectory: vm) }
        func request() throws -> SandboxGuestCommandRequest {
            try SandboxGuestCommandRequest(idempotencyKey: UUID(), executable: "/usr/bin/true")
        }
        func commandDirectory(_ request: SandboxGuestCommandRequest) -> URL {
            installation.appendingPathComponent(request.idempotencyKey.uuidString.lowercased())
        }
        func fillIncompleteDirectories(count: Int) throws {
            for _ in 0..<count {
                try FileManager.default.createDirectory(at: installation.appendingPathComponent(UUID().uuidString.lowercased()),
                    withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
        }
    }
}
