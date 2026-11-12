import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterProcess

/// Private research loop. The Pair remains the request/state ownership authority.
@MainActor final class TimingCohort {
    private(set) var records: [TimingObservation] = []
    private(set) var active: ClusterWorkerRequest?

    func run(pair: ClusterWorkerPair, configuration: TimingSettings, lifetimeDeadline: UInt64,
             publish: (TimingObservation) throws -> Void) async throws {
        try configuration.validate()
        var seen = Set<UUID>()
        for index in 0..<(configuration.warmupCount + configuration.measuredCount) {
            let warmup = index < configuration.warmupCount
            let id = UUID()
            guard seen.insert(id).inserted else { throw QualificationFailure.invalid("Duplicate generated request UUID") }
            var record = TimingObservation(requestID: id.uuidString.lowercased(), phase: warmup ? "warmup" : "measured",
                iteration: warmup ? index : index - configuration.warmupCount, reserveBegan: DispatchTime.now().uptimeNanoseconds)
            var capture: TimingCapture?
            do {
                let deadline = min(lifetimeDeadline, pair.localLifetimeDeadlineUptimeNanoseconds)
                guard record.reserveBegan < deadline, let ready = pair.readiness else {
                    throw QualificationFailure.invalid("Owner lifetime exhausted or Pair unavailable before next request")
                }
                let remaining = deadline - record.reserveBegan
                let requestDeadline = record.reserveBegan + min(remaining, UInt64(configuration.requestSeconds) * 1_000_000_000)
                let value = try pair.reserve(requestID: id, reservation: .init(profileID: ready.profile.id,
                    promptTokenIDs: configuration.promptTokenIDs, stopTokenIDs: [], outputCount: 128, chunkSize: 512,
                    deadlineUptimeNanoseconds: requestDeadline, capacityLimitBytes: ready.requestCapacityBytes))
                active = value; record.reserveCompleted = DispatchTime.now().uptimeNanoseconds
                let sink = TimingCapture(record, expected: configuration.expectedTokenIDs); capture = sink
                // Both stamps use this controller's uptime. This excludes load
                // and reserve, but includes owner transport/control and token delivery.
                sink.markStart(DispatchTime.now().uptimeNanoseconds)
                try value.start { sink.accept($0) }
                await value.waitUntilRetired()
                record = sink.snapshot; record.retirementObserved = DispatchTime.now().uptimeNanoseconds
                guard value.isRetired else { throw QualificationFailure.invalid("Request retirement was not observed") }
                value.releaseResources(); record.resourcesReleased = DispatchTime.now().uptimeNanoseconds
                record.bytesInUseAfterRelease = value.bytesInUse; active = nil
                try record.validateCompleted(expected: configuration.expectedTokenIDs)
            } catch {
                let original = error
                if let value = active {
                    value.cancel(reason: .runtimeError); await value.waitUntilRetired()
                    if let capture { record = capture.snapshot }
                    record.retirementObserved = DispatchTime.now().uptimeNanoseconds
                    if value.isRetired {
                        value.releaseResources(); record.resourcesReleased = DispatchTime.now().uptimeNanoseconds
                        record.bytesInUseAfterRelease = value.bytesInUse
                    }
                    active = nil
                }
                record.completed = false; record.sequenceGuardMatched = false
                record.internalOwnerControlFirstTokenNanoseconds = nil
                record.failure = record.failure ?? String(String(describing: original).prefix(2048))
                records.append(record)
                // Preserve the original failure if writing the partial record fails.
                try? publish(record)
                throw original
            }
            records.append(record)
            try publish(record) // A sink failure aborts the cohort; no retry/reload.
        }
    }
}
