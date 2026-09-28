import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

final class ResidentRecordingTests: XCTestCase {
    private enum Marker: Error { case allocator, capture, encoding }
    private let base = QwenResidentRequestAllowance(stateBytes: 10_000, fusionBytes: 2_000, reservedBytes: 12_000)

    private func charge(rank: Int = 1, padding: Int = 0) throws -> QwenResidentRecordingCharge {
        try .derive(base: base, rank: rank, vocabularySize: 248_320,
            activationDType: "bfloat16", bound: { $0 + padding })
    }

    func testAsymmetricCaptureChargeAndExactCeilings() throws {
        var allocations: [Int] = []
        let first = try QwenResidentRecordingCharge.derive(base: base, rank: 0, vocabularySize: 248_320,
            activationDType: "bfloat16", bound: { allocations.append($0); return $0 })
        XCTAssertTrue(allocations.isEmpty)
        XCTAssertEqual(first.reservedBytes, 12_000)
        let last = try QwenResidentRecordingCharge.derive(base: base, rank: 1, vocabularySize: 248_320,
            activationDType: "bfloat16", bound: { allocations.append($0); return $0 + (allocations.count == 1 ? 17 : 31) })
        XCTAssertEqual(allocations, [496_640, 993_280])
        XCTAssertEqual(last.capture.extraHostBytes, 1_489_920)
        XCTAssertEqual(last.capture.extraNativeBytes, 1_489_968)
        XCTAssertEqual(last.reservedBytes, 2_991_888)
        XCTAssertEqual(last.base.stateBytes, 10_000)
        XCTAssertEqual(last.base.fusionBytes, 2_000)
        XCTAssertEqual(last.capture.originalRequestReservedBytes, 12_000)
        try last.requireCapacity(ownerLimit: 2_991_888, readinessLimit: 2_991_888)
        XCTAssertThrowsError(try last.requireCapacity(ownerLimit: 2_991_887, readinessLimit: Int.max))
        XCTAssertThrowsError(try last.requireCapacity(ownerLimit: Int.max, readinessLimit: 2_991_887))
        XCTAssertThrowsError(try last.requireCapacity(ownerLimit: base.reservedBytes, readinessLimit: Int.max))
        XCTAssertThrowsError(try first.requireCapacity(ownerLimit: 0, readinessLimit: Int.max))
    }

    func testChargeRejectsOverflowInvalidBaseAndPreservesAllocatorFailure() throws {
        for invalid in [
            QwenResidentRequestAllowance(stateBytes: 0, fusionBytes: 0, reservedBytes: 0),
            .init(stateBytes: 10, fusionBytes: -1, reservedBytes: 9),
            .init(stateBytes: 10, fusionBytes: 2, reservedBytes: 11),
            .init(stateBytes: Int.max, fusionBytes: 1, reservedBytes: Int.max),
        ] {
            var calls = 0
            XCTAssertThrowsError(try QwenResidentRecordingCharge.derive(base: invalid, rank: 1,
                vocabularySize: 248_320, activationDType: "bfloat16", bound: { calls += 1; return $0 }))
            XCTAssertEqual(calls, 0)
        }
        let extreme = QwenResidentRequestAllowance(stateBytes: Int.max - 1, fusionBytes: 1, reservedBytes: Int.max)
        XCTAssertThrowsError(try QwenResidentRecordingCharge.derive(base: extreme, rank: 1,
            vocabularySize: 248_320, activationDType: "bfloat16", bound: { $0 }))
        XCTAssertThrowsError(try QwenResidentRecordingCharge.derive(base: base, rank: 1,
            vocabularySize: 248_320, activationDType: "bfloat16", bound: { _ in throw Marker.allocator })) { error in
            guard case Marker.allocator = error else { return XCTFail("Allocator error replaced") }
        }
        XCTAssertThrowsError(try QwenResidentRecordingCharge.derive(base: base, rank: 1,
            vocabularySize: 248_320, activationDType: "bfloat16", bound: { $0 - 1 }))
    }

    func testStoredCaptureChargeRejectsLaterGeometryOrAllocationSubstitution() throws {
        let reserved = try charge()
        try reserved.requireCapture(charge().capture)
        for other in [try charge(rank: 0), try charge(padding: 16_384),
            try QwenResidentRecordingCharge.derive(base: base, rank: 1, vocabularySize: 248_319,
                activationDType: "bfloat16", bound: { $0 }),
            try QwenResidentRecordingCharge.derive(base: .init(stateBytes: 20_000, fusionBytes: 2_000, reservedBytes: 22_000),
                rank: 1, vocabularySize: 248_320, activationDType: "bfloat16", bound: { $0 }),
            try QwenResidentRecordingCharge.derive(base: base, rank: 1, vocabularySize: 248_320,
                activationDType: "float32", bound: { $0 }),
        ] { XCTAssertThrowsError(try reserved.requireCapture(other.capture)) }
    }

    func testReservationModesCannotUpgradeOrDowngrade() throws {
        try QwenResidentRequestMode.serving.require(.serving)
        try QwenResidentRequestMode.recording.require(.recording)
        XCTAssertThrowsError(try QwenResidentRequestMode.serving.require(.recording))
        XCTAssertThrowsError(try QwenResidentRequestMode.recording.require(.serving))
    }

    private func owner() throws -> (QwenResidentControl, QwenLayerStageResidentLifecycle, QwenLayerStageResidentRequestIdentity) {
        let control = QwenResidentControl(deadline: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
        let identity = QwenLayerStageResidentRequestIdentity(requestID: UUID(), epoch: UUID(),
            recordedRequestFingerprint: String(repeating: "a", count: 64))
        try control.loaded(); try control.reserve(identity.requestID)
        return (control, try .init(maximumRequests: 2), identity)
    }

    func testCapacityRemainsHeldUntilScopeRetiresAndOutputIsPrepared() throws {
        let (control, lifecycle, identity) = try owner()
        var order: [String] = []
        let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: identity, deadline: control.deadline, body: {
                order.append("native")
                XCTAssertTrue(lifecycle.snapshot.requestScopeActive)
                XCTAssertFalse(control.available)
                return [271, 99]
            }, prepare: { tokens in
                order.append("encode")
                XCTAssertFalse(lifecycle.snapshot.requestScopeActive)
                XCTAssertEqual(lifecycle.snapshot.completedRequestScopes, 1)
                XCTAssertFalse(control.available)
                XCTAssertThrowsError(try control.reserve(UUID()))
                return Data(tokens.map { UInt8($0 & 255) })
            })
        XCTAssertEqual(order, ["native", "encode"])
        XCTAssertEqual(value, Data([15, 99]))
        XCTAssertTrue(control.available)
        XCTAssertThrowsError(try control.reserve(identity.requestID))
    }

    func testCaptureFailureSkipsEncodingAndWithdrawsCapacity() throws {
        let (control, lifecycle, identity) = try owner()
        var encoded = false
        XCTAssertThrowsError(try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: identity, deadline: control.deadline, body: { () throws -> Int in throw Marker.capture },
            prepare: { value in encoded = true; return value })) { error in
            guard case Marker.capture = error else { return XCTFail("Capture error replaced") }
        }
        XCTAssertFalse(encoded); XCTAssertFalse(control.available)
        XCTAssertFalse(lifecycle.snapshot.requestScopeActive)
        XCTAssertEqual(lifecycle.snapshot.completedRequestScopes, 0)
        XCTAssertTrue(lifecycle.snapshot.failed)
        XCTAssertThrowsError(try control.reserve(UUID()))
    }

    func testEncodingFailureAfterRetirementDoesNotRestoreCapacity() throws {
        let (control, lifecycle, identity) = try owner()
        XCTAssertThrowsError(try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: identity, deadline: control.deadline, body: { 7 },
            prepare: { _ -> Int in
                XCTAssertEqual(lifecycle.snapshot.completedRequestScopes, 1)
                XCTAssertFalse(lifecycle.snapshot.requestScopeActive)
                XCTAssertFalse(control.available)
                throw Marker.encoding
            })) { error in
            guard case Marker.encoding = error else { return XCTFail("Encoding error replaced") }
        }
        XCTAssertEqual(lifecycle.snapshot.completedRequestScopes, 1)
        XCTAssertFalse(control.available)
        XCTAssertThrowsError(try control.reserve(UUID()))
        // Native scope has retired, so explicit local release can still run.
        try control.beginClose()
        var released = false
        try lifecycle.withModelRelease { released = true }
        XCTAssertTrue(released)
    }

    func testCancellationDuringEncodingCannotPublishSuccess() throws {
        let (control, lifecycle, identity) = try owner()
        XCTAssertThrowsError(try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: identity, deadline: control.deadline, body: { 7 },
            prepare: { value in control.cancel(identity.requestID); return value }))
        XCTAssertEqual(lifecycle.snapshot.completedRequestScopes, 1)
        XCTAssertFalse(control.available)
    }

    func testExpiredRequestCannotEncodeOrRestoreCapacity() throws {
        let (control, lifecycle, identity) = try owner()
        var executed = false, encoded = false
        XCTAssertThrowsError(try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
            identity: identity, deadline: 0, body: { executed = true; return 7 },
            prepare: { value in encoded = true; return value }))
        XCTAssertFalse(executed); XCTAssertFalse(encoded); XCTAssertFalse(control.available)
        XCTAssertEqual(lifecycle.snapshot.completedRequestScopes, 0)
    }
}
