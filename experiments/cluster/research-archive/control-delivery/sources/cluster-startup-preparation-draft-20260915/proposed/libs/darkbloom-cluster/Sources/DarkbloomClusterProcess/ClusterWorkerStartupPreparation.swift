import Foundation
import DarkbloomClusterProtocol

/// Startup work is not routed through an HTTP/coordinator/user usage stream.
/// These are observed admission/retirement facts, not native peak-memory or
/// latency claims. The unchanged total lifetime and request quota include it.
public struct ClusterWorkerStartupPreparationResult: Sendable, Equatable {
    public let requestID: UUID
    public let promptTokens: Int
    public let selectedTokens: Int
    public let reservedBytes: Int
    public let elapsedNanoseconds: UInt64
    public let admissionsRemaining: Int
}

public enum ClusterWorkerStartupPreparation {
    /// Synchronous startup-queue operation over the ordinary owned request path.
    /// Cancellation is handled independently by Pair/request watchdogs; neither
    /// this wait nor a deadline fabricates retirement or releases a live lease.
    public static func run(pair: ClusterWorkerPair, recipe: ClusterRuntimeStartupPreparation,
                           chunkSize: Int, deadlineUptimeNanoseconds: UInt64) throws -> ClusterWorkerStartupPreparationResult {
        let started = DispatchTime.now().uptimeNanoseconds
        let before = pair.admissionState
        guard started < deadlineUptimeNanoseconds,
              deadlineUptimeNanoseconds <= pair.localLifetimeDeadlineUptimeNanoseconds,
              before.canAdmit(), before.admissionsRemaining == pair.maximumRequests,
              before.admissionsRemaining > recipe.requestCount, let ready = pair.readiness else {
            throw ClusterWorkerOwnerError.unavailable
        }
        let reservation = try recipe.reservation(profile: ready.profile, chunkSize: chunkSize,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, capacityLimitBytes: ready.requestCapacityBytes)
        let requestID = UUID()
        let request = try pair.reserve(requestID: requestID, reservation: reservation,
                                       admissionDeadline: deadlineUptimeNanoseconds)
        let events = StartupPreparationEvents()
        do {
            let reservedBytes = request.reservedBytes
            try request.start { events.accept($0) }
            request.waitForRetirement()
            guard events.clean(outputCount: recipe.outputCount), request.isRetired else {
                throw ClusterWorkerOwnerError.unavailable
            }
            request.releaseResources()
            let after = pair.admissionState
            let completed = DispatchTime.now().uptimeNanoseconds
            guard request.bytesInUse == 0, after.canAdmit(), pair.readiness != nil,
                  after.admissionsRemaining == before.admissionsRemaining - recipe.requestCount,
                  completed < deadlineUptimeNanoseconds else { throw ClusterWorkerOwnerError.unavailable }
            return .init(requestID: requestID, promptTokens: reservation.promptTokenIDs.count,
                selectedTokens: events.tokenCount, reservedBytes: reservedBytes,
                elapsedNanoseconds: completed - started, admissionsRemaining: after.admissionsRemaining)
        } catch {
            pair.invalidate(); request.cancel(reason: .runtimeError)
            request.waitForRetirement(); request.releaseResources()
            throw error
        }
    }
}

private final class StartupPreparationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var finished: ClusterWorkerFinishReason?
    private var failed = false
    var tokenCount: Int { lock.withLock { count } }
    func accept(_ event: ClusterWorkerRequestEvent) -> Bool {
        lock.withLock {
            switch event {
            case .token: count += 1
            case .finished(let reason): finished = reason
            case .failed: failed = true
            }
            return true
        }
    }
    func clean(outputCount: Int) -> Bool {
        lock.withLock { !failed && finished == .length && count == outputCount }
    }
}
