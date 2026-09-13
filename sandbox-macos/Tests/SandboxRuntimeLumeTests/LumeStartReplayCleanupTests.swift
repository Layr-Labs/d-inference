import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeStartReplayCleanupTests: XCTestCase, @unchecked Sendable {
    func testAlreadyStartingTimeoutRequiresStoppedProof() async throws {
        let fixture = try FakeLumeFixture(initialState: "starting")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 1)
        do {
            try await runtime.start(name: fixture.virtualMachineName)
            XCTFail("starting VM should reach its deadline")
        } catch let error as SandboxRuntimeError {
            guard case .operationTimedOut = error else { return XCTFail("unexpected error: \(error)") }
        }
        let record = try await runtime.inspect(name: fixture.virtualMachineName)
        XCTAssertEqual(record?.state, .stopped)
    }

    func testAlreadyRunningReadinessCancellationStopsBeforeReturning() async throws {
        let fixture = try FakeLumeFixture(initialState: "ready", behavior: "credentialed-readiness-blocking")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(commandTimeoutSeconds: 30)
        let start = Task { try await runtime.start(name: fixture.virtualMachineName) }
        let probe = try await fixture.waitForGuestReadinessProbeToStart()
        start.cancel()
        do { try await start.value; XCTFail("cancelled start should fail") }
        catch is CancellationError { }
        try await fixture.waitForProcessExit(probe)
        let record = try await runtime.inspect(name: fixture.virtualMachineName)
        XCTAssertEqual(record?.state, .stopped)
    }

    func testAlreadyRunningReadinessCancellationRetainsLeaseWhenStopIsUnproven() async throws {
        let fixture = try FakeLumeFixture(initialState: "ready", behavior: "credentialed-readiness-blocking")
        defer { try? fixture.remove() }
        let clock = LumeTestWallClock(Date(timeIntervalSince1970: 2_000_000_000))
        let capacity = try fixture.makeCapacityArbiter(clock: clock)
        let lease = try capacity.reserve(sandboxID: SandboxID(), generation: SandboxGeneration(rawValue: 1)!,
            virtualMachineName: fixture.virtualMachineName, resources: SandboxResourceSpecification.macOSSmall(),
            expiresAt: clock.now().addingTimeInterval(60))
        try fixture.bindOwnership(to: lease.scope)
        let runtime = try fixture.makeLeaseFencedRuntime(capacityArbiter: capacity,
            commandTimeoutSeconds: 30, guestCommandPolicy: .baseImagePreparationAndDevelopment)
        let start = Task { try await runtime.start(scope: lease.scope, name: fixture.virtualMachineName) }
        let probe = try await fixture.waitForGuestReadinessProbeToStart()
        try fixture.setBehavior("stop-liveness-inconclusive")
        start.cancel()
        do { try await start.value; XCTFail("unproven stop must fail cleanup") }
        catch let error as SandboxRuntimeError {
            guard case .cleanupFailed = error else { return XCTFail("unexpected error: \(error)") }
        }
        try await fixture.waitForProcessExit(probe)
        XCTAssertEqual(try capacity.snapshot().leases, [lease])
        let record = try await runtime.inspect(scope: lease.scope, name: fixture.virtualMachineName)
        XCTAssertEqual(record?.state, .running)
    }
}
