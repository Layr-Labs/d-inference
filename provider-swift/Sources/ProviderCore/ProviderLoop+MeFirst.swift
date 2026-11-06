import Foundation

/// Me first: the owner pause.
extension ProviderLoop {
    /// Darkbloom work is paused for the owner.
    var ownerPausesPublic: Bool { false }

    /// Turns me first on for this serving process.
    func enableMeFirst(idle: Duration) {}

    /// A local request's use of this Mac's engine.
    func noteLocalUse(_ use: MeFirstPolicy.LocalUse) {}

    /// Ends the pause once the owner has been idle long enough.
    @discardableResult
    func resumeIfOwnerIdle() -> Bool { false }

    /// Me first as `status` reads it; nil while off.
    var meFirstSnapshot: MeFirstSnapshot? { nil }
}
