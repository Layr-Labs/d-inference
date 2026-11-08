// Me first: the owner's request asks Darkbloom work that hasn't answered to give way while it waits in the engine.

import Foundation

/// The owner's request on a Mac that serves both, me first on (`AcquiredModel.makeRoomForOwner`): bound around the
/// call that starts its engine work, where `EngineV2Bridge.submitTokenized` reads it. Nil for every other request.
enum MeFirstOwnerRequest {
    @TaskLocal static var makeRoom: (@Sendable () async -> Void)?
}

extension EngineV2Bridge {
    /// Engine steps the owner's request stays waiting before it makes room, so one the engine admits at its next step
    /// never asks.
    static let stepsBeforeMakingRoom = 2

    /// Watches the owner's request `id` until its first token or its end. Once it has waited in the engine's queue
    /// (`queueState(of:)`) across `stepsBeforeMakingRoom` steps, it asks Darkbloom work on this model that hasn't
    /// answered to give way (`makeRoom`), so it starts when that work is re-routed. It asks again at every look while
    /// it still waits, so work that was still being admitted at one ask gives way at the next. One timer per such
    /// request, from its submission to its first token; nothing per token.
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
}
