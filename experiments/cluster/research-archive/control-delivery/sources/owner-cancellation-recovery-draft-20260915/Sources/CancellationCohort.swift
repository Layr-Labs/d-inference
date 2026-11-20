import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

@MainActor final class CancellationCohort {
    private(set) var records: [CancellationObservation] = []
    private(set) var active: ClusterWorkerRequest?

    func run(configuration: CancellationSettings, lifetimeDeadline: UInt64,
             makePair: (UUID) async throws -> CancellationOwnedPair,
             publish: (CancellationObservation) throws -> Void) async throws {
        try configuration.validate()
        var seen = Set<UUID>(), prior: ClusterWorkerPair?
        for recovering in [false, true] {
            let epoch = UUID(uuidString: recovering ? configuration.recoveryEpoch : configuration.cancellationEpoch)!
            guard DispatchTime.now().uptimeNanoseconds < lifetimeDeadline else { throw QualificationFailure.invalid("Overall lifetime expired") }
            // This second call is unreachable until first close AND owner ACKs pass.
            let owned = try await makePair(epoch)
            let id = UUID()
            var record = CancellationObservation(phase: recovering ? "recovery" : "cancellation",
                membershipEpoch: epoch.uuidString.lowercased(), requestID: id.uuidString.lowercased())
            var capture: CancellationCapture?, timer: DispatchWorkItem?, original: Error?
            do {
                guard owned.pair !== prior, owned.pair.identity.membershipEpoch == epoch, seen.insert(id).inserted,
                      let ready = owned.pair.readiness else { throw QualificationFailure.invalid("Fresh Pair/epoch readiness required") }
                prior = owned.pair
                let now = DispatchTime.now().uptimeNanoseconds
                let end = min(lifetimeDeadline, owned.pair.localLifetimeDeadlineUptimeNanoseconds)
                guard now < end else { throw QualificationFailure.invalid("Request starts outside lifetime") }
                let request = try owned.pair.reserve(requestID: id, reservation: .init(profileID: ready.profile.id,
                    promptTokenIDs: configuration.promptTokenIDs, stopTokenIDs: [], outputCount: 128, chunkSize: 512,
                    deadlineUptimeNanoseconds: now + min(end - now, UInt64(configuration.requestSeconds) * 1_000_000_000),
                    capacityLimitBytes: ready.requestCapacityBytes))
                active = request; record.reservedBytes = request.reservedBytes
                let sink = CancellationCapture(record, expected: configuration.expectedTokenIDs,
                    selectedCase: recovering ? nil : configuration.cancellationCase); capture = sink
                sink.markStart()
                try request.start { [weak request] event in
                    guard let request else { return false }
                    return sink.accept(event, request: request, pair: owned.pair)
                }
                if !recovering && configuration.cancellationCase == .startedBeforeFirstToken {
                    let pair = owned.pair
                    let cancelAction: @Sendable () -> Void = { [weak request] in
                        if let request { sink.cancel(request, pair: pair) }
                    }
                    let work = DispatchWorkItem(block: cancelAction)
                    timer = work
                    DispatchQueue.global().asyncAfter(deadline: .init(uptimeNanoseconds: sink.snapshot.startCalled!
                        + UInt64(configuration.beforeFirstDelayMilliseconds) * 1_000_000), execute: work)
                }
                await request.waitUntilRetired(); timer?.cancel()
                record = sink.snapshot; record.retirementObserved = DispatchTime.now().uptimeNanoseconds
                guard request.isRetired else { throw QualificationFailure.invalid("Retirement wait lacks actual proof") }
                request.releaseResources(); record.resourcesReleased = DispatchTime.now().uptimeNanoseconds
                record.bytesAfterRelease = request.bytesInUse; active = nil
                guard record.bytesAfterRelease == 0, record.failure == nil else {
                    throw QualificationFailure.invalid(record.failure ?? "Request charge retained after release")
                }
                if recovering {
                    guard record.cancelCalled == nil, record.finishReason == "length", record.failureCallback == nil,
                          record.tokenIDs == configuration.expectedTokenIDs else { throw QualificationFailure.invalid("Fresh-epoch recovery sequence or finish differs") }
                } else {
                    guard record.phaseMatched, record.retiredBeforeCancel == false, record.pairUnavailableAfterCancel,
                          record.finishReason == nil, record.cancelCalled != nil else {
                        throw QualificationFailure.invalid("Cancellation did not interrupt selected active phase")
                    }
                }
            } catch {
                original = error; timer?.cancel()
                if let request = active {
                    request.cancel(reason: .runtimeError); await request.waitUntilRetired()
                    if let capture { record = capture.snapshot }
                    record.retirementObserved = DispatchTime.now().uptimeNanoseconds
                    request.releaseResources(); record.resourcesReleased = DispatchTime.now().uptimeNanoseconds
                    record.bytesAfterRelease = request.bytesInUse; active = nil
                }
                record.failure = record.failure ?? String(String(describing: error).prefix(2048))
            }
            let proof = await owned.close(lifetimeDeadline: lifetimeDeadline)
            record.nativeCleanupObserved = proof.native; record.ownerLeaseReleaseObserved = proof.leases
            record.cleanupCompleted = proof.nativeAt; record.ownerLeaseDrainCompleted = proof.leasesAt
            if proof.native != [true, true] || proof.leases != [true, true] {
                record.failure = record.failure ?? "Missing actual native cleanup or authenticated owner lease release"
                original = original ?? QualificationFailure.invalid(record.failure!)
            }
            record.completed = original == nil; records.append(record)
            if let original { try? publish(record); throw original }
            try publish(record) // Publication failure also prevents recovery/retry.
        }
    }
}
