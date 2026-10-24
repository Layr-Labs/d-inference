/// Decision gate for an immediate update check triggered by
/// `runtime_status{verified:false}`.
///
/// The coordinator re-sends `runtime_status` on every ~5-minute attestation
/// challenge while a provider stays unverified, so reacting to every message
/// would start an update check every 5 minutes for as long as the mismatch
/// persists. This gate enforces a 10-minute minimum spacing on top of the
/// existing auto-update opt-outs (`config.provider.autoUpdate`,
/// `DARKBLOOM_NO_UPDATE_CHECK`) so the coordinator-driven trigger behaves the
/// operator already agreed to for the background poll, just sooner.
///
/// Pure decision only -- carries no state of its own. The caller records
/// `lastCheckAt` and invokes the existing `AutoUpdateController` path (which
/// itself single-flights via its cross-process lease) when this returns true.
public enum RuntimeOutdatedUpdateTrigger {
    /// Minimum spacing between coordinator-triggered update checks (10 min).
    public static let minimumSpacingSeconds: Double = 600

    public static func shouldCheck(
        autoUpdateEnabled: Bool,
        envDisabled: Bool,
        lastCheckAt: Double?,
        now: Double
    ) -> Bool {
        guard autoUpdateEnabled, !envDisabled else { return false }
        guard let lastCheckAt else { return true }
        return now - lastCheckAt >= minimumSpacingSeconds
    }
}
