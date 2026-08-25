import Foundation
import SandboxCore
import SandboxHostControl
import SandboxRuntime
@testable import DarkbloomSandboxDaemon
import XCTest

final class SandboxHostProductionAdapterTests: XCTestCase {
    func testPrepareAdoptsCoordinatorFenceAndReportsDurableHighWatermark()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let payload = try fixture.preparePayload(fencingToken: 40)

        let response = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: payload, type: .prepare)
        ))
        guard case .operation(let status) = response else {
            return XCTFail("expected prepare operation response")
        }
        XCTAssertEqual(status.operationID, payload.operationID)
        XCTAssertEqual(status.operation, "prepare")
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.scope, payload.scope)

        let snapshot = try fixture.capacity.snapshot()
        XCTAssertEqual(snapshot.nextFencingToken, 41)
        XCTAssertEqual(snapshot.leases.count, 1)
        let heartbeat = try await fixture.adapter.heartbeat()
        XCTAssertEqual(heartbeat.nextFencingToken, 41)
        XCTAssertEqual(heartbeat.availableCPU, 4)
        XCTAssertEqual(
            heartbeat.availableMemoryBytes,
            8 * SandboxResourcePolicy.gibibyte
        )
        XCTAssertEqual(heartbeat.leases.count, 1)
        XCTAssertEqual(heartbeat.leases[0].state, .ready)
        XCTAssertEqual(
            heartbeat.leases[0].resources.commandTimeoutSeconds,
            900
        )
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events,
            [
                "create:\(Fixture.virtualMachineName(for: payload.scope))",
                "start:\(Fixture.virtualMachineName(for: payload.scope))",
            ]
        )
    }

    func testPrepareFailsClosedBeforeReservingWithoutIsolationGates()
        async throws
    {
        let fixture = try Fixture(isolationReadiness: .unavailable)
        defer { fixture.remove() }
        let payload = try fixture.preparePayload(fencingToken: 1)

        let response = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: payload, type: .prepare)
        ))
        guard case .operation(let status) = response else {
            return XCTFail("expected failed prepare operation response")
        }
        XCTAssertEqual(status.state, .failed)
        XCTAssertEqual(status.errorCode, "isolation_unavailable")
        XCTAssertTrue(try fixture.capacity.snapshot().leases.isEmpty)
        let heartbeat = try await fixture.adapter.heartbeat()
        XCTAssertEqual(heartbeat.mode, SandboxHostMode.draining.rawValue)
        XCTAssertEqual(heartbeat.availableCPU, 8)
        XCTAssertEqual(
            heartbeat.availableMemoryBytes,
            16 * SandboxResourcePolicy.gibibyte
        )
        let events = await fixture.runtime.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testRenewReturnsNewFenceAndRoutesDeleteAndRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let prepare = try fixture.preparePayload(fencingToken: 20)
        _ = try await fixture.adapter.handle(.prepare(
            fixture.envelope(payload: prepare, type: .prepare)
        ))
        let renew = SandboxWireLeaseRenew(
            operationID: UUID(),
            scope: prepare.scope,
            requestedFencingToken: SandboxFencingToken(rawValue: 21)!,
            leaseExpiresAt: Fixture.timestamp(
                fixture.now.addingTimeInterval(240)
            )
        )

        let renewedResponse = try await fixture.adapter.handle(.leaseRenew(
            fixture.envelope(payload: renew, type: .leaseRenew)
        ))
        guard case .operation(let renewed) = renewedResponse else {
            return XCTFail("expected renewal operation response")
        }
        XCTAssertEqual(renewed.operation, "renew")
        XCTAssertEqual(renewed.state, .ready)
        XCTAssertEqual(renewed.scope.fencingToken.rawValue, 21)

        let deletion = SandboxWireOperation(
            operationID: UUID(),
            scope: renewed.scope
        )
        let deletedResponse = try await fixture.adapter.handle(.delete(
            fixture.envelope(payload: deletion, type: .delete)
        ))
        guard case .operation(let deleted) = deletedResponse else {
            return XCTFail("expected delete operation response")
        }
        XCTAssertEqual(deleted.state, .deleted)
        let events = await fixture.runtime.events()
        XCTAssertEqual(
            events.last,
            "delete:\(Fixture.virtualMachineName(for: renewed.scope))"
        )
    }

    func testCommandCancellationInterruptsRuntimeWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        await fixture.runtime.blockCommands()
        let scope = Fixture.scope(fencingToken: 7)
        let command = SandboxWireCommand(
            commandID: UUID(),
            idempotencyKey: UUID().uuidString.lowercased(),
            scope: scope,
            arguments: ["/usr/bin/printf", "hello"],
            timeoutSeconds: 900
        )
        let running = Task {
            try await fixture.adapter.handle(.command(
                fixture.envelope(payload: command, type: .command)
            ))
        }
        await fixture.runtime.waitUntilCommandStarted()
        let cancellation = SandboxWireCommandControl(
            operationID: UUID(),
            commandID: command.commandID,
            scope: scope
        )

        let cancelledResponse = try await fixture.adapter.handle(.cancelCommand(
            fixture.envelope(payload: cancellation, type: .cancelCommand)
        ))
        guard case .command(let cancelled) = cancelledResponse else {
            return XCTFail("expected cancelled command response")
        }
        XCTAssertEqual(cancelled.state, .cancelled)
        guard case .command(let original) = try await running.value else {
            return XCTFail("expected original command response")
        }
        XCTAssertEqual(original.state, .cancelled)
    }
}

private final class Fixture: @unchecked Sendable {
    let root: URL
    let now: Date
    let capacity: SandboxHostCapacityArbiter
    let runtime = RecordingSandboxRuntime()
    let adapter: SandboxHostProductionAdapter

    init(
        isolationReadiness: SandboxHostIsolationReadiness = .init(
            signedGuestControl: true,
            networkPolicy: true,
            workspaceQuota: true
        )
    ) throws {
        let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)
        now = fixedNow
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "darkbloom-host-adapter-\(UUID().uuidString)",
            isDirectory: true
        )
        let state = root.appendingPathComponent("state", isDirectory: true)
        let storage = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        capacity = try SandboxHostCapacityArbiter(
            stateDirectory: state,
            policy: SandboxCapacityPolicy(
                maximumReservedCPUCount: 8,
                maximumReservedMemoryBytes:
                    16 * SandboxResourcePolicy.gibibyte,
                maximumReservedGrowthBytes:
                    300 * SandboxResourcePolicy.gibibyte,
                storageHeadroomBytes:
                    20 * SandboxResourcePolicy.gibibyte
            ),
            currentDate: { fixedNow },
            availableStorageBytes: { UInt64.max }
        )
        _ = try capacity.initialize()
        _ = try capacity.setMode(.sandboxDedicated)
        adapter = SandboxHostProductionAdapter(
            capacity: capacity,
            runtime: runtime,
            isolationReadiness: isolationReadiness
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func preparePayload(fencingToken: UInt64) throws -> SandboxWirePrepare {
        SandboxWirePrepare(
            operationID: UUID(),
            scope: Self.scope(fencingToken: fencingToken),
            resources: SandboxWireResources(
                cpuCount: 4,
                memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
                workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
                commandTimeoutSeconds: 900,
                gpu: false
            ),
            baseImageID: "macos-tahoe-v1",
            leaseExpiresAt: Self.timestamp(now.addingTimeInterval(120))
        )
    }

    func envelope<Payload>(
        payload: Payload,
        type: SandboxControlMessageType
    ) -> SandboxControlEnvelope<Payload>
    where Payload: Codable & Equatable & Sendable {
        SandboxControlEnvelope(
            type: type,
            hostID: UUID(),
            connectionEpoch: UUID(),
            sequence: 1,
            payload: payload
        )
    }

    static func scope(fencingToken: UInt64) -> SandboxWireScope {
        SandboxWireScope(
            sandboxID: SandboxID(
                "11111111-1111-1111-1111-111111111111"
            )!,
            generation: SandboxGeneration(rawValue: 1)!,
            fencingToken: SandboxFencingToken(rawValue: fencingToken)!
        )
    }

    static func virtualMachineName(for scope: SandboxWireScope) -> String {
        "sbx-11111111111111111111111111111111-g\(scope.generation.rawValue)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(from: date)
    }
}

private actor RecordingSandboxRuntime: SandboxHostVirtualMachineControlling {
    private var records: [String: SandboxVirtualMachineRecord] = [:]
    private var recordedEvents: [String] = []
    private var shouldBlockCommands = false
    private var commandStarted = false
    private var commandStartedWaiter: CheckedContinuation<Void, Never>?

    func inspect(
        scope _: SandboxOperationScope,
        name: String
    ) async throws -> SandboxVirtualMachineRecord? {
        records[name]
    }

    func create(
        scope _: SandboxOperationScope,
        specification: SandboxVirtualMachineSpecification
    ) async throws {
        recordedEvents.append("create:\(specification.name)")
        records[specification.name] = SandboxVirtualMachineRecord(
            name: specification.name,
            state: .stopped,
            cpuCount: specification.resources.cpuCount,
            memoryBytes: specification.resources.memoryBytes,
            diskBytes: specification.diskBytes,
            guestReady: false
        )
    }

    func start(
        scope _: SandboxOperationScope,
        name: String
    ) async throws {
        recordedEvents.append("start:\(name)")
        guard let record = records[name] else {
            throw SandboxRuntimeError.unsupported("missing test VM")
        }
        records[name] = SandboxVirtualMachineRecord(
            name: name,
            state: .running,
            cpuCount: record.cpuCount,
            memoryBytes: record.memoryBytes,
            diskBytes: record.diskBytes,
            guestReady: true
        )
    }

    func execute(
        scope _: SandboxOperationScope,
        name _: String,
        request _: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        commandStarted = true
        commandStartedWaiter?.resume()
        commandStartedWaiter = nil
        if shouldBlockCommands {
            try await Task.sleep(for: .seconds(3_600))
        }
        return SandboxGuestCommandResult(
            exitCode: 0,
            standardOutput: Data("hello".utf8),
            standardError: Data()
        )
    }

    func stop(
        scope _: SandboxOperationScope,
        name: String
    ) async throws {
        recordedEvents.append("stop:\(name)")
        guard let record = records[name] else {
            return
        }
        records[name] = SandboxVirtualMachineRecord(
            name: name,
            state: .stopped,
            cpuCount: record.cpuCount,
            memoryBytes: record.memoryBytes,
            diskBytes: record.diskBytes,
            guestReady: false
        )
    }

    func deleteAndRelease(
        scope _: SandboxOperationScope,
        name: String
    ) async throws {
        recordedEvents.append("delete:\(name)")
        records.removeValue(forKey: name)
    }

    func events() -> [String] {
        recordedEvents
    }

    func blockCommands() {
        shouldBlockCommands = true
    }

    func waitUntilCommandStarted() async {
        if commandStarted {
            return
        }
        await withCheckedContinuation {
            commandStartedWaiter = $0
        }
    }
}
