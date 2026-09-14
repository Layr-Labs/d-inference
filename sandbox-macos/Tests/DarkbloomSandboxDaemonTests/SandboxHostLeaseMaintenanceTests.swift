import Foundation
import SandboxCore
import SandboxRuntime
import SandboxRuntimeLume
@testable import DarkbloomSandboxDaemon
import XCTest

final class SandboxHostLeaseMaintenanceTests: XCTestCase, @unchecked Sendable {
    func testIdleLeaseExpiresWithoutAnyCoordinatorConnection() async throws {
        let state = State(leases: [Self.lease()], date: Date(timeIntervalSince1970: 0))
        let events = Events()
        let maintenance = SandboxHostLeaseMaintenance(snapshot: { state.leases },
            cancelCommands: { _ in await events.append("cancel") },
            reconcile: {
                guard state.date >= Date(timeIntervalSince1970: 60) else { return [] }
                await events.append("stop-proof")
                let leases = state.leases
                state.removeLeases()
                return leases.map { .init(lease: $0, outcome: .released) }
            }, now: { state.date }, sleep: { _ in
                if state.advance(seconds: 120) > 1 { throw CancellationError() }
            }, diagnostic: { _ in })
        do { try await maintenance.run(); XCTFail("fake clock ends the loop") }
        catch is CancellationError {}
        XCTAssertTrue(state.leases.isEmpty)
        let observed = await events.values
        XCTAssertEqual(observed, ["cancel", "stop-proof"])
    }

    func testActiveCancellationCompletesBeforeReconciliation() async throws {
        let events = Events()
        let command = Task<Void, Error> {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { await events.append("command-cleanup-finished"); throw error }
        }
        let maintenance = SandboxHostLeaseMaintenance(snapshot: { [Self.lease()] },
            cancelCommands: { _ in command.cancel(); _ = try? await command.value },
            reconcile: { await events.append("reconcile"); return [] },
            now: { Date(timeIntervalSince1970: 120) }, diagnostic: { _ in })
        _ = try await maintenance.sweep()
        let observed = await events.values
        XCTAssertEqual(observed, ["command-cleanup-finished", "reconcile"])
    }

    func testUnknownStopRetainsLeaseAndNextSweepRetries() async throws {
        let state = State(leases: [Self.lease()], date: Date(timeIntervalSince1970: 120))
        let attempts = Events()
        let maintenance = SandboxHostLeaseMaintenance(snapshot: { state.leases }, cancelCommands: { _ in },
            reconcile: {
                let count = await attempts.append("attempt")
                let lease = state.leases[0]
                if count == 1 { return [.init(lease: lease, outcome: .retained("stop proof unavailable"))] }
                state.removeLeases()
                return [.init(lease: lease, outcome: .released)]
            }, now: { state.date }, diagnostic: { _ in })
        let first = try await maintenance.sweep()
        XCTAssertEqual(first.first?.outcome, .retained("stop proof unavailable"))
        XCTAssertEqual(state.leases.count, 1)
        let second = try await maintenance.sweep()
        XCTAssertEqual(second.first?.outcome, .released)
        XCTAssertTrue(state.leases.isEmpty)
        let observed = await attempts.values
        XCTAssertEqual(observed.count, 2)
    }

    func testRepeatedRetainedDiagnosticIsBoundedAndRecoveryIsReported() async throws {
        let state = State(leases: [Self.lease()], date: Date(timeIntervalSince1970: 120))
        let attempts = Events(), logs = Log()
        let maintenance = SandboxHostLeaseMaintenance(snapshot: { state.leases }, cancelCommands: { _ in },
            reconcile: {
                let count = await attempts.append("attempt")
                if count < 3 { return [.init(lease: Self.lease(), outcome: .retained("internal path omitted"))] }
                state.removeLeases()
                return [.init(lease: Self.lease(), outcome: .released)]
            }, now: { state.date }, sleep: { _ in
                if state.advance(seconds: 1) >= 3 { throw CancellationError() }
            }, diagnostic: { logs.append($0) })
        do { try await maintenance.run() } catch is CancellationError {}
        XCTAssertEqual(logs.values.count, 2)
        XCTAssertTrue(logs.values[0].contains("retained 1"))
        XCTAssertEqual(logs.values[1], "sandbox lease maintenance recovered")
    }

    private static func lease() -> SandboxCapacityLease {
        SandboxCapacityLease(scope: SandboxOperationScope(sandboxID: SandboxID(),
            generation: SandboxGeneration(rawValue: 1)!, fencingToken: SandboxFencingToken(rawValue: 1)!),
            virtualMachineName: "expired", cpuCount: 2, memoryBytes: 4 << 30, workspaceBytes: 25 << 30,
            bootDiskBytes: 100 << 30, reservedGrowthBytes: 126 << 30,
            issuedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 60))
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedLeases: [SandboxCapacityLease]
        private var storedDate: Date
        private var steps = 0
        init(leases: [SandboxCapacityLease], date: Date) { storedLeases = leases; storedDate = date }
        var leases: [SandboxCapacityLease] { lock.withLock { storedLeases } }
        var date: Date { lock.withLock { storedDate } }
        func removeLeases() { lock.withLock { storedLeases = [] } }
        func advance(seconds: TimeInterval) -> Int {
            lock.withLock { steps += 1; storedDate += seconds; return steps }
        }
    }
    private actor Events {
        var values: [String] = []
        @discardableResult func append(_ value: String) -> Int { values.append(value); return values.count }
    }
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []
        var values: [String] { lock.withLock { messages } }
        func append(_ value: String) { lock.withLock { messages.append(value) } }
    }
}
