import Foundation
import XCTest
import DarkbloomClusterProtocol
import DarkbloomClusterRemote

final class ClusterOwnerLeaseStateTests: XCTestCase {
    let child = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let requestID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    func binding(cluster: String = "fixture", incarnation: UUID? = nil, lease: UUID? = nil,
                 epoch: UUID? = nil, rank: Int = 0) throws -> ClusterOwnerBinding {
        let identity = ClusterWorkerIdentity(
            membershipEpoch: epoch ?? UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            modelID: "invented", artifactSHA256: String(repeating: "a", count: 64),
            configurationSHA256: String(repeating: "b", count: 64),
            peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
                    .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
        let profile = ClusterWorkerProfile(id: "invented", vocabularySize: 1000,
            maximumPromptTokens: 8, maximumOutputTokens: 4, maximumChunkTokens: 4, maximumContextTokens: 12)
        return try .init(clusterID: cluster,
            ownerIncarnation: incarnation ?? UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            leaseID: lease ?? UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            identity: identity, profile: profile, rank: rank,
            executionPlanSHA256: String(repeating: "e", count: 64))
    }

    func readiness(_ binding: ClusterOwnerBinding, capacity: Int = 100) -> ClusterWorkerReady {
        .init(identity: binding.identity, rank: binding.rank, profile: binding.profile,
              executionPlanSHA256: binding.executionPlanSHA256, requestCapacityBytes: capacity)
    }

    func loaded() throws -> ClusterOwnerLeaseState {
        var value = try ClusterOwnerLeaseState(binding: binding(), now: 100, remainingLifetimeNanoseconds: 1000)
        try value.beginNativeLaunch(child, now: 101)
        try value.observeNativeStarted(child)
        try value.observeReady(readiness(value.binding), launchID: child, now: 102)
        return value
    }

    func send(_ control: ClusterOwnerControl, to state: inout ClusterOwnerLeaseState,
              now: UInt64 = 110) throws -> ClusterOwnerAction {
        let frame = ClusterOwnerControlFrame(route: state.binding.route, sequence: state.nextControlSequence, control: control)
        return try state.accept(frame, now: now)
    }

    func reserved() throws -> ClusterOwnerLeaseState {
        var state = try loaded()
        XCTAssertEqual(try send(.reserve(requestID: requestID, capacityLimitBytes: 80, remainingNanoseconds: 500), to: &state),
                       .forwardReserve(requestID, localDeadlineUptimeNanoseconds: 610))
        XCTAssertEqual(state.status.chargedRequestBytes, 80)
        try state.observeAdmitted(requestID: requestID, reservedBytes: 60)
        return state
    }

    func testCleanRequestReleaseAndActualExitAreSeparate() throws {
        var state = try reserved()
        XCTAssertEqual(try send(.start(requestID: requestID), to: &state, now: 120), .forwardStart(requestID))
        try state.observeRetired(requestID: requestID, retirement: .clean)
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        XCTAssertFalse(state.canReleaseDeviceLease)
        XCTAssertEqual(try send(.release(requestID: requestID), to: &state, now: 130), .releaseRequestResources(requestID))
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        try state.observeRequestResourcesReleased(requestID: requestID)
        XCTAssertEqual(state.status.chargedRequestBytes, 0)
        XCTAssertTrue(state.status.ready)
        XCTAssertEqual(try send(.shutdown, to: &state, now: 140), .sendShutdown)
        XCTAssertNil(state.terminal)
        try state.observeNativeTerminal(launchID: child, termination: .exited(status: 0))
        XCTAssertTrue(state.canReleaseDeviceLease)
        XCTAssertNil(state.terminal)
        try state.observeDeviceLeaseReleased()
        let terminal = try XCTUnwrap(state.terminal)
        XCTAssertEqual(terminal.releasedRequestCount, 1)
        XCTAssertEqual(terminal.native.termination, .exited(status: 0))
        XCTAssertThrowsError(try state.observeDeviceLeaseReleased())
        XCTAssertEqual(state.terminal, terminal)
    }

    func testTimeoutAndDisconnectNeverInventExitOrRelease() throws {
        var state = try reserved()
        try state.observeTime(609)
        XCTAssertFalse(state.status.quarantined)
        try state.observeTime(610)
        state.disconnect()
        XCTAssertTrue(state.requiresNativeFence)
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        XCTAssertNil(state.status.nativeTerminal)
        XCTAssertNil(state.terminal)
        XCTAssertThrowsError(try send(.release(requestID: requestID), to: &state, now: 611))
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        try state.observeNativeTerminal(launchID: child, termination: .signalled(signal: 9))
        _ = try send(.release(requestID: requestID), to: &state, now: 612)
        try state.observeRequestResourcesReleased(requestID: requestID)
        try state.observeDeviceLeaseReleased()
        XCTAssertNotNil(state.terminal)
    }

    func testRefusalKeepsPendingCeilingUntilNativeFenced() throws {
        var state = try loaded()
        _ = try send(.reserve(requestID: requestID, capacityLimitBytes: 80, remainingNanoseconds: 500), to: &state)
        try state.observeRefused(requestID: requestID)
        XCTAssertEqual(state.status.chargedRequestBytes, 80)
        XCTAssertTrue(state.requiresNativeFence)
        XCTAssertFalse(state.status.ready)
        XCTAssertThrowsError(try send(.release(requestID: requestID), to: &state))
        XCTAssertFalse(state.canReleaseDeviceLease)
    }

    func testStaleRoutingAndSequencePoisonWithoutDroppingOwnership() throws {
        let routes = try [binding(cluster: "other"), binding(incarnation: UUID()), binding(lease: UUID()),
                          binding(epoch: UUID()), binding(rank: 1)].map(\.route)
        for route in routes {
            var state = try reserved()
            XCTAssertThrowsError(try state.accept(.init(route: route, sequence: state.nextControlSequence,
                control: .start(requestID: requestID)), now: 120))
            XCTAssertTrue(state.requiresNativeFence)
            XCTAssertEqual(state.status.chargedRequestBytes, 60)
            XCTAssertEqual(state.nextControlSequence, 1)
        }
        var state = try reserved()
        XCTAssertThrowsError(try state.accept(.init(route: state.binding.route, sequence: 0,
            control: .start(requestID: requestID)), now: 120))
        XCTAssertTrue(state.requiresNativeFence)
        XCTAssertEqual(state.nextControlSequence, 1)
    }

    func testWrongChildCannotSupplyFenceProof() throws {
        var state = try reserved()
        state.disconnect()
        XCTAssertThrowsError(try state.observeNativeTerminal(launchID: UUID(), termination: .exited(status: 0)))
        XCTAssertNil(state.status.nativeTerminal)
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        XCTAssertFalse(state.canReleaseDeviceLease)
    }

    func testCancelNeverBecomesCleanStopOrStartsAgain() throws {
        var state = try reserved()
        XCTAssertEqual(try send(.cancel(requestID: requestID, reason: .callerCancelled), to: &state),
                       .forwardCancel(requestID, .callerCancelled))
        XCTAssertThrowsError(try send(.start(requestID: requestID), to: &state))
        XCTAssertThrowsError(try state.observeRetired(requestID: requestID, retirement: .clean))
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        try state.observeRetired(requestID: requestID, retirement: .cancelled)
        _ = try send(.release(requestID: requestID), to: &state)
        try state.observeRequestResourcesReleased(requestID: requestID)
        XCTAssertFalse(state.status.ready)
        XCTAssertTrue(state.requiresNativeFence)
    }

    func testCleanRetirementBeforeStartIsRejected() throws {
        var state = try reserved()
        XCTAssertThrowsError(try state.observeRetired(requestID: requestID, retirement: .clean))
        XCTAssertEqual(state.status.chargedRequestBytes, 60)
        XCTAssertThrowsError(try state.observeRequestResourcesReleased(requestID: requestID))
    }

    func testLateAdmissionAfterDisconnectStillChargesActualReservation() throws {
        var state = try loaded()
        _ = try send(.reserve(requestID: requestID, capacityLimitBytes: 80, remainingNanoseconds: 500), to: &state)
        state.disconnect()
        try state.observeAdmitted(requestID: requestID, reservedBytes: 70)
        XCTAssertEqual(state.status.chargedRequestBytes, 70)
        XCTAssertTrue(state.requiresNativeFence)
        XCTAssertThrowsError(try send(.start(requestID: requestID), to: &state))
        try state.observeRetired(requestID: requestID, retirement: .failed)
        _ = try send(.release(requestID: requestID), to: &state)
        try state.observeRequestResourcesReleased(requestID: requestID)
        XCTAssertFalse(state.canReleaseDeviceLease)
    }

    func testDoubleReservationAndRequestIDReplayRefuse() throws {
        var pending = try reserved()
        XCTAssertThrowsError(try send(.reserve(requestID: UUID(), capacityLimitBytes: 10, remainingNanoseconds: 10), to: &pending))
        XCTAssertEqual(pending.status.activeRequestID, requestID)
        XCTAssertEqual(pending.status.chargedRequestBytes, 60)
        var retired = try reserved()
        _ = try send(.start(requestID: requestID), to: &retired)
        try retired.observeRetired(requestID: requestID, retirement: .clean)
        _ = try send(.release(requestID: requestID), to: &retired)
        try retired.observeRequestResourcesReleased(requestID: requestID)
        XCTAssertThrowsError(try send(.reserve(requestID: requestID, capacityLimitBytes: 10, remainingNanoseconds: 10), to: &retired))
        XCTAssertTrue(retired.requiresNativeFence)
    }

    func testUnknownRecoveredOwnershipCannotLaunchOrClaimZeroCapacity() throws {
        for id in [nil, child] as [UUID?] {
            var state = ClusterOwnerLeaseState.recoveredUnresolved(binding: try binding(), launchID: id, now: 100)
            XCTAssertTrue(state.status.recoveredUnresolved)
            XCTAssertTrue(state.status.quarantined)
            XCTAssertNil(state.status.chargedRequestBytes)
            XCTAssertFalse(state.status.ready)
            XCTAssertThrowsError(try state.beginNativeLaunch(child, now: 101))
            XCTAssertThrowsError(try state.observeNativeTerminal(launchID: child, termination: .exited(status: 0)))
            XCTAssertThrowsError(try state.closeBeforeLaunch())
            XCTAssertThrowsError(try state.observeDeviceLeaseReleased())
            XCTAssertNil(state.terminal)
        }
    }

    func testReleaseRequiresActualObservationAndIsExactlyOnce() throws {
        var state = try reserved()
        _ = try send(.start(requestID: requestID), to: &state)
        try state.observeRetired(requestID: requestID, retirement: .clean)
        XCTAssertThrowsError(try state.observeRequestResourcesReleased(requestID: requestID))
        _ = try send(.release(requestID: requestID), to: &state)
        try state.observeRequestResourcesReleased(requestID: requestID)
        XCTAssertThrowsError(try state.observeRequestResourcesReleased(requestID: requestID))
        XCTAssertEqual(state.status.chargedRequestBytes, 0)
    }

    func testLaunchFailureAndNeverLaunchedAreDistinctFromReaped() throws {
        var failed = try ClusterOwnerLeaseState(binding: binding(), now: 100, remainingLifetimeNanoseconds: 1000)
        try failed.beginNativeLaunch(child, now: 101)
        try failed.observeNativeTerminal(launchID: child, termination: .launchFailed)
        try failed.observeDeviceLeaseReleased()
        XCTAssertEqual(failed.terminal?.native.termination, .launchFailed)
        var unused = try ClusterOwnerLeaseState(binding: binding(), now: 100, remainingLifetimeNanoseconds: 1000)
        unused.disconnect()
        try unused.closeBeforeLaunch()
        try unused.observeDeviceLeaseReleased()
        XCTAssertEqual(unused.terminal?.native.termination, .neverLaunched)
        XCTAssertNil(unused.terminal?.native.launchID)
    }

    func testLifetimeAndReservationLimitsUseLocalClockWithoutExtension() throws {
        XCTAssertThrowsError(try ClusterOwnerLeaseState(binding: binding(), now: UInt64.max, remainingLifetimeNanoseconds: 1))
        XCTAssertThrowsError(try ClusterOwnerLeaseState(binding: binding(), now: 100, remainingLifetimeNanoseconds: 0))
        var state = try loaded()
        XCTAssertEqual(try send(.reserve(requestID: requestID, capacityLimitBytes: 80, remainingNanoseconds: 2000), to: &state),
                       .forwardReserve(requestID, localDeadlineUptimeNanoseconds: 1100))
        try state.observeTime(600)
        try state.observeTime(1099)
        XCTAssertFalse(state.status.quarantined)
        try state.observeTime(1100)
        XCTAssertTrue(state.requiresNativeFence)
        XCTAssertEqual(state.status.chargedRequestBytes, 80)
        XCTAssertThrowsError(try state.observeTime(1099))
    }

    func testReadinessAndAdmissionUseActualBindingAndBoundedCapacity() throws {
        for capacity in [0, -1, ClusterWorkerLimits.capacityBytes + 1] {
            var state = try ClusterOwnerLeaseState(binding: binding(), now: 100, remainingLifetimeNanoseconds: 1000)
            try state.beginNativeLaunch(child, now: 101); try state.observeNativeStarted(child)
            XCTAssertThrowsError(try state.observeReady(readiness(state.binding, capacity: capacity), launchID: child, now: 102))
            XCTAssertFalse(state.status.ready)
        }
        for bytes in [0, 81] {
            var state = try loaded()
            _ = try send(.reserve(requestID: requestID, capacityLimitBytes: 80, remainingNanoseconds: 500), to: &state)
            XCTAssertThrowsError(try state.observeAdmitted(requestID: requestID, reservedBytes: bytes))
            XCTAssertEqual(state.status.chargedRequestBytes, 80)
            XCTAssertTrue(state.requiresNativeFence)
        }
    }
}
