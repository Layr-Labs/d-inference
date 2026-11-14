// Whether a request still waits in the engine's queue: what me first (`EngineV2Bridge+OwnerWait.swift`) and a streamed
// local request's held head (`EngineV2Bridge+HeadHold.swift`) read.

import Foundation

extension EngineV2Bridge {
    /// Whether request `id` waits in the engine's queue, and the engine's step count; nil once it has its first token
    /// or has ended, or the engine has shut down.
    ///
    /// No engine signal says that one request was admitted, so the bridge infers it. The engine admits waiting
    /// requests by priority, then in arrival order (every request the provider submits has priority 0 but a loop
    /// exit's continuation, `EngineAdmissionPriority`), so the waiting ones are the last it would admit: a request
    /// waits while the engine's waiting count is larger than the number of this bridge's live requests it would
    /// admit after it (a lower priority, or the same one and submitted later). The count is published after each engine step and counts a request from its
    /// submission, so a request reads as waiting until the step that admits it has run. Errors lean toward waiting: an
    /// older request preempted and requeued at the front counts as waiting, so a running request can read as waiting
    /// until its first token. Reading admitted too early takes a race, such as a newer request the engine has ended
    /// that still counts here until the bridge records its end.
    func queueState(of id: String) -> (waiting: Bool, steps: Int)? {
        guard let state = active[id], state.firstTokenAt == nil, let snapshot = ownedEngine?.capacity() else {
            return nil
        }
        let after = active.values.reduce(0) {
            $0 + ($1.priority < state.priority
                || ($1.priority == state.priority && $1.submittedAt > state.submittedAt) ? 1 : 0)
        }
        return (snapshot.waitingRequests > after, snapshot.stepsExecuted)
    }

    func setQueuePollIntervalForTesting(_ interval: Duration) {
        queuePollInterval = interval
    }
}
