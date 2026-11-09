// Me first: the owner's request asks queued Darkbloom work to give way while it waits in the engine.

import Foundation

/// The owner's request on a Mac that serves both, me first on (`AcquiredModel.makeRoomForOwner`): bound around the
/// call that starts its engine work, where `EngineV2Bridge.submitTokenized` reads it. Nil for every other request.
enum MeFirstOwnerRequest {
    @TaskLocal static var makeRoom: (@Sendable () async -> Void)?
}

/// A Darkbloom request: its coordinator id, bound around the call that starts its stream
/// (`ProviderLoop.handleInferenceRequest`), where `EngineV2Bridge.submitTokenized` records it, so me first can tell
/// whether the engine has admitted it (`hasAdmitted(darkbloomRequest:)`). It is bound after the model's load, so no
/// calibration session inherits it. Nil for every other request.
enum MeFirstDarkbloomRequest {
    @TaskLocal static var id: String?
}

extension EngineV2Bridge {
    /// Engine steps the owner's request stays waiting before it makes room, so one the engine admits at its next step
    /// never asks.
    static let stepsBeforeMakingRoom = 2

    /// Watches the owner's request `id` until its first token or its end. Once it has waited in the engine's queue
    /// (`queueState(of:)`) across `stepsBeforeMakingRoom` steps, it asks Darkbloom work on this model that is still
    /// queued to give way (`makeRoom`), so it starts when that work is re-routed. It asks again at every look while it
    /// still waits, so work that was still being admitted at one ask, or that the engine put back in its queue, gives
    /// way at the next. One timer per such request, from its submission to its first token; nothing per token.
    func watchOwnerWait(id: String, makeRoom: @escaping @Sendable () async -> Void) {
        let interval = queuePollInterval
        Task { [weak self] in
            var stepsWhenFirstSeenWaiting: Int?
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, let queue = await self.queueState(of: id) else { return }
                guard queue.waiting else {
                    stepsWhenFirstSeenWaiting = nil
                    continue
                }
                let firstSeen = stepsWhenFirstSeenWaiting ?? queue.steps
                stepsWhenFirstSeenWaiting = firstSeen
                if queue.steps >= firstSeen + Self.stepsBeforeMakingRoom { await makeRoom() }
            }
        }
    }

    /// Whether request `id` waits in the engine's queue, and the engine's step count; nil once it has its first token
    /// or has ended, or the engine has shut down.
    ///
    /// No engine signal says that one request was admitted, so the bridge infers it. The engine admits waiting
    /// requests in arrival order (every request the provider submits has priority 0), so the waiting ones are the
    /// newest it holds: a request waits while the engine's waiting count is larger than the number of this bridge's
    /// live requests submitted after it. The count is published after each engine step and counts a request from its
    /// submission, so a request reads as waiting until the step that admits it has run. Errors lean toward waiting: an
    /// older request preempted and requeued at the front counts as waiting, so a running request can read as waiting
    /// until its first token. Reading admitted too early takes a race, such as a newer request the engine has ended
    /// that still counts here until the bridge records its end.
    func queueState(of id: String) -> (waiting: Bool, steps: Int)? {
        guard let state = active[id], state.firstTokenAt == nil, let snapshot = ownedEngine?.capacity() else {
            return nil
        }
        let newer = active.values.reduce(0) { $0 + ($1.submittedAt > state.submittedAt ? 1 : 0) }
        return (snapshot.waitingRequests > newer, snapshot.stepsExecuted)
    }

    /// Whether the engine has admitted the Darkbloom request with coordinator id `requestId`: it is in the engine and
    /// doesn't wait in its queue (`queueState(of:)`), so it is in its prompt or past it. Such a request keeps its work
    /// when the owner's request waits (`ProviderLoop.giveWayToOwner`). False before it reaches the engine and while it
    /// waits in the queue, including after the engine has put it back there (preempted for memory, its prompt's work
    /// gone).
    func hasAdmitted(darkbloomRequest requestId: String) -> Bool {
        guard let id = active.first(where: { $0.value.darkbloomRequestId == requestId })?.key else { return false }
        return queueState(of: id)?.waiting != true
    }

    func setQueuePollIntervalForTesting(_ interval: Duration) {
        queuePollInterval = interval
    }
}
