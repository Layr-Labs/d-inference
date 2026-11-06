import Foundation
import MLXLMCommon
@testable import ProviderCore

enum RotationScenarios {
    static func normal(_ owners: RotationOwners, host: DistributedLocalServer, discovery: RotationDiscovery) async throws -> [RotationHTTPReceipt] {
        let initial = await host.status
        guard let port = initial.boundPort else { throw RotationCheckError(message: "No bound port") }
        let published = discovery.value
        var receipts: [RotationHTTPReceipt] = []
        for ordinal in 0..<33 {
            let generationIndex = ordinal / 16
            try await rotationEventually {
                let status = await host.status
                return owners.snapshot.count == generationIndex + 1 && status.phase == .serving
            }
            let record = owners.snapshot[generationIndex]
            try owners.observeReady(record)
            receipts.append(try await RotationHTTP.complete(port: port, model: record.session.model.publicModelID,
                ordinal: ordinal, epoch: record.session.expectedIdentity.membershipEpoch))
            try rotationRequire(discovery.value == published && discovery.writeCount == 1,
                                "Rotation rewrote or removed listener discovery")
        }
        let epochs = Set(receipts.map(\.epoch))
        try rotationRequire(epochs.count == 3 && owners.snapshot.count == 3, "Two real quota boundaries did not rotate exactly twice")
        try await RotationHTTP.health(port: port)
        let stopped = await host.stop(until: rotationDeadline())
        try rotationRequire(stopped.cleanupComplete && !stopped.failed, "Normal rotated host did not cleanly stop")
        for record in owners.snapshot { try owners.validateReleased(record) }
        try rotationRequire(discovery.value == nil, "Own discovery survived final shutdown")
        return receipts
    }

    /// The last reservation really runs and retires in both protocol children,
    /// but its HTTP acquisition and response remain held independently.
    static func heldResponse(_ owners: RotationOwners, host: DistributedLocalServer, discovery: RotationDiscovery) async throws -> [RotationHTTPReceipt] {
        let receipts = try await exhaustPrefix(15, owners: owners, host: host)
        let first = owners.snapshot[0]
        guard let port = await host.status.boundPort else { throw RotationCheckError(message: "No bound port") }
        let published = discovery.value, generation = await host.generation
        let acquisition = try await host.acquire(first.session.model.publicModelID)
        let response = try generation.responses.begin()
        let lease = try first.session.reserve(.init(id: .init(999), promptTokens: [1, 2, 3],
            sampling: .init(temperature: 0), maxTokens: 2), identity: first.session.expectedIdentity,
            profileID: first.session.profile.id, capacityLimit: 1800,
            deadlineContext: .init(generationDeadline: ContinuousClock.now.advanced(by: .seconds(3))))
        do {
            try lease.start { _ in true }
            await lease.waitUntilRetired()
            lease.releaseResources()
            try await rotationEventually { await host.status.phase == .rotating }
            try rotationRequire(owners.snapshot.count == 1, "Held generation allowed premature factory call")
            try await RotationHTTP.health(port: port)
            await acquisition.releaseToken.fire()
            try await Task.sleep(for: .milliseconds(40))
            try rotationRequire(owners.snapshot.count == 1 && discovery.value == published,
                                "Response hold did not retain old generation")
            response.finish()
            try await rotationEventually {
                let status = await host.status
                return owners.snapshot.count == 2 && status.phase == .serving
            }
            // The replacement now legitimately owns the same canonical locks.
            // The factory checked empty/unlocked before starting this generation.
            try owners.validateReleaseProof(first)
            try owners.observeReady(owners.snapshot[1])
        } catch {
            lease.cancel(); await lease.waitUntilRetired(); lease.releaseResources()
            response.finish(); await acquisition.releaseToken.fire()
            throw error
        }
        let stopped = await host.stop(until: rotationDeadline())
        try rotationRequire(stopped.cleanupComplete && !stopped.failed && discovery.writeCount == 1,
                            "Held-response rotation did not finish cleanly")
        try owners.validateReleased(owners.snapshot[1])
        return receipts
    }

    static func failedRelease(_ owners: RotationOwners, host: DistributedLocalServer) async throws -> [RotationHTTPReceipt] {
        let receipts = try await exhaustPrefix(16, owners: owners, host: host)
        let first = owners.snapshot[0]
        try await rotationEventually {
            first.endpoints.values.count == 2 && first.endpoints.values.allSatisfy {
                $0.nativeCleanupObserved && $0.ownerTermination != nil
            }
        }
        try rotationRequire(owners.snapshot.count == 1 && !first.session.canRotate,
                            "Missing ACK/nonzero owner permitted replacement")
        let bounded = await host.stop(until: DispatchTime.now().uptimeNanoseconds + 20_000_000)
        try rotationRequire(bounded.phase == .quarantined && !bounded.cleanupComplete,
                            "Missing release proof was reported as complete cleanup")
        // The existing fixed endpoint deadline bounds the retained release wait.
        // Natural owner exit/empty journal alone never makes this reusable.
        try await rotationEventually(seconds: 16) { await host.teardownTask == nil }
        let final = await host.status
        try rotationRequire(final.phase == .quarantined && !final.cleanupComplete && owners.snapshot.count == 1,
                            "Quarantined generation was discarded or replaced")
        let expectedExit = owners.behavior == "drop-release" ? 0 : 7
        try rotationRequire(first.endpoints.values.allSatisfy {
            $0.nativeCleanupObserved && $0.ownerTermination == .exited(Int32(expectedExit)) &&
                $0.ownerDeviceLeaseReleasedObserved == (owners.behavior == "nonzero-owner")
        }, "Actual failure did not match the requested ACK/exit seam")
        return receipts
    }

    static func stopDuringStart(_ owners: RotationOwners, host: DistributedLocalServer) async throws -> [RotationHTTPReceipt] {
        guard let gate = owners.startupGate else { throw RotationCheckError(message: "Missing startup gate") }
        let receipts = try await exhaustPrefix(16, owners: owners, host: host)
        try await rotationEventually { gate.isEntered && owners.snapshot.count == 2 }
        let candidate = owners.snapshot[1]
        try rotationRequire(candidate.endpoints.values.count == 1, "Stop seam did not retain exactly one started owner")
        let bounded = await host.stop(until: DispatchTime.now().uptimeNanoseconds + 20_000_000)
        try rotationRequire(bounded.phase == .quarantined && !bounded.cleanupComplete,
                            "Stop during startup dropped its pending obligation")
        gate.open()
        try await rotationEventually(seconds: 8) { await host.teardownTask == nil }
        try rotationRequire(owners.snapshot.count == 2 && candidate.endpoints.values.count == 1,
                            "Canceled startup launched a late second owner or another generation")
        try rotationRequire(candidate.endpoints.values.allSatisfy {
            $0.nativeCleanupObserved && $0.ownerDeviceLeaseReleasedObserved && $0.ownerTermination == .exited(0)
        }, "Partial startup lost actual owned-child cleanup")
        let final = await host.status
        try rotationRequire(final.cleanupComplete, "Partial-start host failed to observe eventual cleanup")
        return receipts
    }

    private static func exhaustPrefix(_ count: Int, owners: RotationOwners, host: DistributedLocalServer) async throws -> [RotationHTTPReceipt] {
        let record = owners.snapshot[0]
        try owners.observeReady(record)
        guard let port = await host.status.boundPort else { throw RotationCheckError(message: "No bound port") }
        var receipts: [RotationHTTPReceipt] = []
        for ordinal in 0..<count {
            receipts.append(try await RotationHTTP.complete(port: port, model: record.session.model.publicModelID,
                ordinal: ordinal, epoch: record.session.expectedIdentity.membershipEpoch))
        }
        return receipts
    }
}
