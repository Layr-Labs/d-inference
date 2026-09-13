import Darwin
import Foundation
import SandboxCore
@testable import SandboxRuntime
import XCTest

final class HostCapacityResumeTests: XCTestCase {
    func testResumeRetryAfterPublicationFailureRequiresFreshDurabilityWithoutChangingLease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resume-durability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fault = ResumeSynchronizationFault()
        func open() throws -> SandboxHostCapacityArbiter {
            try SandboxHostCapacityArbiter(stateDirectory: directory,
                policy: SandboxCapacityPolicy(maximumReservedCPUCount: 8,
                    maximumReservedMemoryBytes: 16 * SandboxResourcePolicy.gibibyte,
                    maximumReservedGrowthBytes: 300 * SandboxResourcePolicy.gibibyte,
                    storageHeadroomBytes: 20 * SandboxResourcePolicy.gibibyte),
                currentDate: { now }, availableStorageBytes: { UInt64.max },
                directorySynchronizationError: { fault.synchronize($0) })
        }
        let initial = try open()
        _ = try initial.initialize()
        _ = try initial.setMode(.sandboxDedicated)
        let lease = try initial.reserve(sandboxID: SandboxID(), generation: SandboxGeneration(rawValue: 1)!,
            virtualMachineName: "resume-durability", resources: SandboxResourceSpecification.macOSSmall(),
            expiresAt: now.addingTimeInterval(120))
        let requested = SandboxFencingToken(rawValue: 10)!
        fault.setFailure(true)
        for attempt in 0..<2 {
            let broker = attempt == 0 ? initial : try open()
            XCTAssertThrowsError(try broker.resume(scope: lease.scope, fencingToken: requested, expiresAt: lease.expiresAt)) {
                XCTAssertEqual($0 as? SandboxCapacityError, .publicationUncertain(EIO), "attempt \(attempt)")
            }
            let visible = try XCTUnwrap(broker.snapshot().leases.first)
            XCTAssertEqual(visible.scope.fencingToken, requested)
            XCTAssertEqual(visible.expiresAt, lease.expiresAt)
            XCTAssertEqual(visible.issuedAt, lease.issuedAt)
            XCTAssertEqual(visible.reservedGrowthBytes, lease.reservedGrowthBytes)
            XCTAssertThrowsError(try broker.authorize(scope: lease.scope,
                virtualMachineName: lease.virtualMachineName, operation: .stop)) {
                XCTAssertEqual($0 as? SandboxCapacityError, .staleFencingToken)
            }
        }
        fault.setFailure(false)
        let restarted = try open()
        let resumed = try restarted.resume(scope: lease.scope, fencingToken: requested, expiresAt: lease.expiresAt)
        let snapshot = try restarted.snapshot()
        XCTAssertEqual(snapshot.leases, [resumed])
        XCTAssertEqual(snapshot.nextFencingToken, 11)
        XCTAssertEqual(resumed.expiresAt, lease.expiresAt)
        XCTAssertEqual(resumed.issuedAt, lease.issuedAt)
        XCTAssertEqual(resumed.cpuCount, lease.cpuCount)
        XCTAssertEqual(resumed.memoryBytes, lease.memoryBytes)
        XCTAssertEqual(resumed.workspaceBytes, lease.workspaceBytes)
        XCTAssertEqual(resumed.bootDiskBytes, lease.bootDiskBytes)
        XCTAssertEqual(resumed.reservedGrowthBytes, lease.reservedGrowthBytes)
        XCTAssertEqual(try restarted.authorize(scope: resumed.scope,
            virtualMachineName: lease.virtualMachineName, operation: .stop), resumed)
    }
}

private final class ResumeSynchronizationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func setFailure(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func synchronize(_ descriptor: Int32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if failing { return EIO }
        while fsync(descriptor) != 0 { if errno != EINTR { return errno } }
        return nil
    }
}
