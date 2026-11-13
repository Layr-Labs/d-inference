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

    /// Whether the engine has admitted the Darkbloom request with coordinator id `requestId`: it is in the engine and
    /// doesn't wait in its queue (`queueState(of:)`), so it is in its prompt or past it. Such a request keeps its work
    /// when the owner's request waits (`ProviderLoop.giveWayToOwner`). False before it reaches the engine and while it
    /// waits in the queue, including after the engine has put it back there (preempted for memory, its prompt's work
    /// gone). A loop exit's continuation (priority above 0, `EngineAdmissionPriority`) counts as admitted: its
    /// request's thought has already streamed, so it never gives way.
    func hasAdmitted(darkbloomRequest requestId: String) -> Bool {
        guard let entry = active.first(where: { $0.value.darkbloomRequestId == requestId }) else { return false }
        if entry.value.priority > 0 { return true }
        return queueState(of: entry.key)?.waiting != true
    }
}
