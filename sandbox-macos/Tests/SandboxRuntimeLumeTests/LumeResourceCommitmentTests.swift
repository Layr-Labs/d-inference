import Foundation
import SandboxCore
import SandboxRuntime
@testable import SandboxRuntimeLume
import XCTest

final class LumeResourceCommitmentTests: XCTestCase {
    func testCPUCommitmentDriftFailsClosedForLeaseOwnershipAndObservation()
        async throws
    {
        try await assertIndependentDriftIsRejected(dimension: .cpu)
    }

    func testMemoryCommitmentDriftFailsClosedForLeaseOwnershipAndObservation()
        async throws
    {
        try await assertIndependentDriftIsRejected(dimension: .memory)
    }

    func testDiskCommitmentDriftFailsClosedForLeaseOwnershipAndObservation()
        async throws
    {
        try await assertIndependentDriftIsRejected(dimension: .disk)
    }

    func testScopedDeleteRejectsResourceDriftAndRetainsCapacity()
        async throws
    {
        let baseline = ResourceCommitmentValues.baseline
        let observed = baseline.replacingCPUCount(2)
        let fixture = try FakeLumeFixture(
            initialState: "stopped",
            observedCPUCount: observed.cpuCount,
            observedMemoryBytes: observed.memoryBytes,
            observedDiskBytes: observed.diskBytes
        )
        defer { try? fixture.remove() }
        let context = try makeContext(
            fixture: fixture,
            lease: baseline,
            ownership: baseline
        )

        do {
            try await context.runtime.delete(
                scope: context.lease.scope,
                name: context.lease.virtualMachineName
            )
            XCTFail("scoped delete must reject observed resource drift")
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(error, .leaseResourceMismatch)
        }

        XCTAssertEqual(
            try context.arbiter.snapshot().leases,
            [context.lease]
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.virtualMachineDirectory.path
            )
        )
    }

    private func assertIndependentDriftIsRejected(
        dimension: ResourceCommitmentDimension
    ) async throws {
        for source in ResourceCommitmentDriftSource.allCases {
            try await assertDriftIsRejected(
                dimension: dimension,
                source: source
            )
        }
    }

    private func assertDriftIsRejected(
        dimension: ResourceCommitmentDimension,
        source: ResourceCommitmentDriftSource
    ) async throws {
        let values = ResourceCommitmentDrift(
            dimension: dimension,
            source: source
        )
        let fixture = try FakeLumeFixture(
            initialState: "stopped",
            observedCPUCount: values.observed.cpuCount,
            observedMemoryBytes: values.observed.memoryBytes,
            observedDiskBytes: values.observed.diskBytes
        )
        defer { try? fixture.remove() }
        let context = try makeContext(
            fixture: fixture,
            lease: values.lease,
            ownership: values.ownership
        )

        do {
            _ = try await context.runtime.inspect(
                scope: context.lease.scope,
                name: context.lease.virtualMachineName
            )
            XCTFail(
                "\(dimension.rawValue) drift in \(source.rawValue) must fail closed"
            )
        } catch let error as SandboxCapacityError {
            XCTAssertEqual(
                error,
                .leaseResourceMismatch,
                "\(dimension.rawValue) drift in \(source.rawValue)"
            )
        }

        XCTAssertEqual(
            try context.arbiter.snapshot().leases,
            [context.lease],
            "\(dimension.rawValue) drift in \(source.rawValue) must retain capacity"
        )
        let observed = try await fixture.makeRuntime().inspect(
            name: fixture.virtualMachineName
        )
        XCTAssertEqual(observed?.state, .stopped)
    }

    private func makeContext(
        fixture: FakeLumeFixture,
        lease: ResourceCommitmentValues,
        ownership: ResourceCommitmentValues
    ) throws -> ResourceCommitmentContext {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let arbiter = try fixture.makeCapacityArbiter(
            clock: LumeTestWallClock(now)
        )
        let capacityLease = try arbiter.reserve(
            sandboxID: SandboxID(),
            generation: try XCTUnwrap(SandboxGeneration(rawValue: 1)),
            virtualMachineName: fixture.virtualMachineName,
            resources: try lease.makeResourceSpecification(),
            bootDiskBytes: lease.diskBytes,
            expiresAt: now.addingTimeInterval(120)
        )
        try fixture.bindOwnership(
            to: capacityLease.scope,
            resources: try ownership.makeResourceSpecification(),
            diskBytes: ownership.diskBytes
        )
        return ResourceCommitmentContext(
            arbiter: arbiter,
            lease: capacityLease,
            runtime: try fixture.makeLeaseFencedRuntime(
                capacityArbiter: arbiter
            )
        )
    }
}

private enum ResourceCommitmentDimension: String, Equatable {
    case cpu
    case memory
    case disk
}

private enum ResourceCommitmentDriftSource: String, CaseIterable {
    case lease
    case ownership
    case observation
}

private struct ResourceCommitmentDrift {
    let lease: ResourceCommitmentValues
    let ownership: ResourceCommitmentValues
    let observed: ResourceCommitmentValues

    init(
        dimension: ResourceCommitmentDimension,
        source: ResourceCommitmentDriftSource
    ) {
        let baseline = ResourceCommitmentValues.baseline
        let alternate = baseline.replacing(dimension: dimension)
        switch source {
        case .lease:
            if dimension == .disk {
                // The alpha capacity policy only admits 100 GiB leases. Make
                // ownership plus observation agree on 101 GiB so the lease is
                // still the independently differing commitment.
                lease = baseline
                ownership = alternate
                observed = alternate
            } else {
                lease = alternate
                ownership = baseline
                observed = baseline
            }
        case .ownership:
            lease = baseline
            ownership = alternate
            observed = baseline
        case .observation:
            lease = baseline
            ownership = baseline
            observed = alternate
        }
    }
}

private struct ResourceCommitmentValues {
    let cpuCount: UInt16
    let memoryBytes: UInt64
    let diskBytes: UInt64

    static let baseline = ResourceCommitmentValues(
        cpuCount: 4,
        memoryBytes: 8 * SandboxResourcePolicy.gibibyte,
        diskBytes: 100 * SandboxResourcePolicy.gibibyte
    )

    func makeResourceSpecification() throws
        -> SandboxResourceSpecification
    {
        try SandboxResourceSpecification(
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            workspaceBytes: 25 * SandboxResourcePolicy.gibibyte,
            commandTimeoutSeconds: 900
        )
    }

    func replacing(
        dimension: ResourceCommitmentDimension
    ) -> ResourceCommitmentValues {
        switch dimension {
        case .cpu:
            replacingCPUCount(2)
        case .memory:
            ResourceCommitmentValues(
                cpuCount: cpuCount,
                memoryBytes: 4 * SandboxResourcePolicy.gibibyte,
                diskBytes: diskBytes
            )
        case .disk:
            ResourceCommitmentValues(
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                diskBytes: 101 * SandboxResourcePolicy.gibibyte
            )
        }
    }

    func replacingCPUCount(
        _ cpuCount: UInt16
    ) -> ResourceCommitmentValues {
        ResourceCommitmentValues(
            cpuCount: cpuCount,
            memoryBytes: memoryBytes,
            diskBytes: diskBytes
        )
    }
}

private struct ResourceCommitmentContext {
    let arbiter: SandboxHostCapacityArbiter
    let lease: SandboxCapacityLease
    let runtime: LumeLeaseFencedVirtualMachineRuntime
}
