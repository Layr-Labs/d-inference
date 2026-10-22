// CoordinatorClient: a starting cluster member's registration wait. The wait
// belongs to the member's ProviderLoop; the client keeps its reconnects inside
// it and reports how the wait stands when it ends.

import Foundation

/// How a starting member's registration stands when its wait reaches its
/// deadline. Read by `ProviderLoop.waitForClusterMemberRegistration`.
enum ClusterMemberRegistrationProgress: Sendable, Equatable {
    /// An attempt is still within its own terms: the reconnect the wait
    /// placed at its deadline, or any attempt under way at the deadline (its
    /// handshake, then this connection's negotiation window). Never later.
    case finalAttempt(until: ContinuousClock.Instant)
    /// The latest attempt could not reach the coordinator: nothing answered,
    /// so nothing accepted or refused the member role.
    case unreachable(reason: String)
    /// A coordinator was reached and did not accept the role in time.
    case notAccepted
}

extension CoordinatorClient {
    /// The next reconnect delay of a member whose registration is awaited.
    /// Backoff stays as it is, except that a retry is never placed after the
    /// wait's deadline: one that would be is moved to the deadline itself and
    /// marked final, so a coordinator back before the wait ends is reached
    /// before the waiting command gives up (a doubling backoff otherwise
    /// skips past the deadline: 1+2+4+8+16 s > 30 s).
    static func memberReconnectDelay(backoff seconds: TimeInterval,
                                     deadline: ContinuousClock.Instant?,
                                     now: ContinuousClock.Instant) -> (seconds: TimeInterval, final: Bool) {
        guard let deadline, now < deadline else { return (seconds, false) }
        let remaining = deadline - now
        let remainingSeconds = Double(remaining.components.seconds)
            + Double(remaining.components.attoseconds) / 1e18
        return remainingSeconds <= seconds ? (remainingSeconds, true) : (seconds, false)
    }

    func setMemberRegistrationDeadline(_ deadline: ContinuousClock.Instant?) {
        guard config.executionRole == .clusterMember else { return }
        memberRegistrationDeadline = deadline
    }

    /// An ended wait clears its own deadline only, never a later wait's.
    func clearMemberRegistrationDeadline(_ deadline: ContinuousClock.Instant) {
        if memberRegistrationDeadline == deadline { memberRegistrationDeadline = nil }
    }

    func memberRegistrationProgress(now: ContinuousClock.Instant = .now) -> ClusterMemberRegistrationProgress {
        let open = [memberFinalAttemptUntil, memberAttemptUntil].compactMap { $0 }.filter { now < $0 }
        if let until = open.max() { return .finalAttempt(until: until) }
        if let reason = memberUnreachableReason { return .unreachable(reason: reason) }
        return .notAccepted
    }

    /// The reconnect loop's delay after a failed or closed attempt. The
    /// attempt that just ended is no longer the final one.
    func nextMemberAwareReconnectDelay(backoff seconds: TimeInterval,
                                       now: ContinuousClock.Instant = .now) -> TimeInterval {
        memberFinalAttemptUntil = nil
        let planned = Self.memberReconnectDelay(backoff: seconds,
            deadline: config.executionRole == .clusterMember ? memberRegistrationDeadline : nil, now: now)
        if planned.final {
            // Its terms: the handshake gets one negotiation window from its
            // start; a ready transport then gets its own (connectAndRun).
            memberFinalAttemptUntil = now.advanced(by: .seconds(planned.seconds))
                .advanced(by: ClusterMemberNegotiation.window)
        }
        return planned.seconds
    }

    /// An attempt's handshake begins: it gets one negotiation window to
    /// reach the coordinator, so a wait whose deadline falls inside it does
    /// not give up on it (nor call it a refusal). Only an attempt begun
    /// before the deadline, or the final one placed at it, counts: later
    /// reconnects never extend a wait (it ends within two windows of its
    /// deadline whatever the coordinator does).
    func noteMemberAttemptStarted(now: ContinuousClock.Instant = .now) {
        guard config.executionRole == .clusterMember else { return }
        if let deadline = memberRegistrationDeadline, now >= deadline, memberFinalAttemptUntil == nil {
            memberAttemptUntil = nil
            return
        }
        memberAttemptUntil = now.advanced(by: ClusterMemberNegotiation.window)
    }

    /// The handshake of this attempt failed: the coordinator was not reached.
    func noteMemberAttemptUnreachable(_ error: Error) {
        guard config.executionRole == .clusterMember else { return }
        memberAttemptUntil = nil
        memberUnreachableReason = String(describing: error)
    }

    /// This attempt's transport is ready and its registration is about to be
    /// sent under `negotiation`: the attempt (final or not) now runs to its
    /// connection's window, where an unacknowledged member is refused anyway.
    func noteMemberTransportReady(_ negotiation: ClusterMemberNegotiation?) {
        memberUnreachableReason = nil
        if memberAttemptUntil != nil { memberAttemptUntil = negotiation?.deadline }
        if memberFinalAttemptUntil != nil, let negotiation { memberFinalAttemptUntil = negotiation.deadline }
    }

    /// The attempt's connection is gone (any exit): nothing of it is open.
    func noteMemberAttemptEnded() {
        memberAttemptUntil = nil
    }
}
