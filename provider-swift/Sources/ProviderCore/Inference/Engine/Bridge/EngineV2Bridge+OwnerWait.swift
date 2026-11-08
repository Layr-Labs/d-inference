// Me first: the owner's request asks Darkbloom work that hasn't answered to give way while it waits in the engine.

import Foundation

/// The owner's request on a Mac that serves both, me first on (`AcquiredModel.ownerWaits`): bound around the call that
/// starts its engine work, where `EngineV2Bridge.submitTokenized` reads it. Nil for every other request.
enum MeFirstOwnerRequest {
    @TaskLocal static var waits: (@Sendable () async -> Void)?
}

extension EngineV2Bridge {
    /// Watches the owner's request `id` until its first token or its end. While it waits in the engine's queue, it asks
    /// Darkbloom work on this model that hasn't answered to give way (`waits`), so it starts when that work is re-routed.
    ///
    /// No engine signal says that one request was admitted, so the bridge infers it. The engine admits waiting requests
    /// in arrival order (every request has the same priority), so the waiting ones are the newest it holds: the request
    /// waits while the engine's published waiting count is larger than the number of this bridge's live requests
    /// submitted after it. The count is published after each engine step and counts a request from its submission, so a
    /// request always reads as waiting until the first step that could admit it; giving way starts only once two more
    /// steps have passed with it still waiting. A preempted request, requeued at the front, reads as waiting too, so the
    /// inference errs toward giving way, never toward leaving the owner's request queued. One timer per such request,
    /// nothing per token.
    func watchOwnerWait(id: String, waits: @escaping @Sendable () async -> Void) {
        let interval = ownerWaitPollInterval
        Task { [weak self] in
            var stepsWhenFirstSeenWaiting: Int?
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, let view = await self.ownerWaitView(id: id) else { return }
                guard view.waiting else {
                    stepsWhenFirstSeenWaiting = nil
                    continue
                }
                let first = stepsWhenFirstSeenWaiting ?? view.steps
                stepsWhenFirstSeenWaiting = first
                if view.steps >= first + 2 { await waits() }
            }
        }
    }

    /// Whether request `id` waits in the engine's queue, and the engine's step count; nil once it has its first token
    /// or has ended, or the engine has shut down.
    func ownerWaitView(id: String) -> (waiting: Bool, steps: Int)? {
        guard let state = active[id], state.firstTokenAt == nil, let snapshot = ownedEngine?.capacity() else {
            return nil
        }
        let newer = active.values.reduce(0) { $0 + ($1.submittedAt > state.submittedAt ? 1 : 0) }
        return (snapshot.waitingRequests > newer, snapshot.stepsExecuted)
    }

    func setOwnerWaitPollIntervalForTesting(_ interval: Duration) {
        ownerWaitPollInterval = interval
    }
}
