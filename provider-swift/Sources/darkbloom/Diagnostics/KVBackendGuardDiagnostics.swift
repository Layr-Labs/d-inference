import Foundation
import ProviderCore

/// Operator-facing rendering of the crash-loop KV-backend guard
/// (`KVBackendGuard`) for `darkbloom status` and `darkbloom doctor`.
///
/// Pure over its inputs (record injected, clock injected) so the wording —
/// which explains a guarded automatic selection — is pinned by tests rather
/// than eyeballed. The record does not expose the model's resolved precision.
///
/// Two states, rendered differently on purpose:
///
///   * ACTIVE (record version == running version): guarded automatic AR
///     builds use contiguous only at native precision; packed precision refuses. Names
///     native recovery and both guard exits — the
///     next release, and `darkbloom doctor --clear-backend-guard` — so the
///     line never reads as a permanent verdict.
///   * STALE (version differs): the record is inert (the factory's version
///     check ignores it) and the next daemon start deletes it. Rendered so
///     an operator reading `status` between the release landing and the
///     daemon restarting does not conclude the guard still binds.
enum KVBackendGuardDiagnostics {

    private static let activeSelectionGuidance =
        "packed autoregressive `.auto` (`balanced`/`k8v4`/`k8v8`) requires paged and is refused while guarded; "
        + "clear with `darkbloom doctor --clear-backend-guard` to permit a paged retry; "
        + "explicit legacy `native` recovery permits contiguous `.auto`"

    /// The `darkbloom status` block: empty when no guard record exists
    /// (the healthy fleet-wide case prints nothing rather than a reassuring
    /// extra line), one line otherwise.
    static func statusLines(
        record: KVBackendGuard?,
        now: Double,
        runningVersion: String
    ) -> [String] {
        guard let record else { return [] }
        if record.providerVersion == runningVersion {
            return [
                "KV-backend guard: ACTIVE — \(activeSelectionGuidance) "
                    + "(tripped \(ageText(record: record, now: now)) ago on "
                    + "v\(record.providerVersion) after \(record.crashCount) crash-loop "
                    + "restarts; also clears on the next release)"
            ]
        }
        return [
            "KV-backend guard: stale — tripped on v\(record.providerVersion), this "
                + "binary is v\(runningVersion); inert, removed at next daemon start"
        ]
    }

    /// The `darkbloom doctor` check row. WARN, never FAIL: the guard record
    /// describes selection policy, not whether a slot is serving or refused.
    /// `doctor --strict` still escalates this warning.
    static func doctorCheck(
        record: KVBackendGuard,
        now: Double,
        runningVersion: String
    ) -> DoctorCheck {
        guard record.providerVersion == runningVersion else {
            return DoctorCheck(
                name: "kv backend crash-loop guard",
                status: .warn,
                detail: "stale record from v\(record.providerVersion) (this binary is "
                    + "v\(runningVersion)) — inert, removed at next daemon start")
        }
        return DoctorCheck(
            name: "kv backend crash-loop guard",
            status: .warn,
            detail: "ACTIVE — \(activeSelectionGuidance); tripped "
                + "\(ageText(record: record, now: now)) ago on v\(record.providerVersion) "
                + "after \(record.crashCount) crash-loop restarts. Also clears on the next "
                + "release.")
    }

    /// Coarse human age ("41s", "12m", "5h", "3d") — the reader needs "how
    /// long ago the guard tripped", not a timestamp to subtract.
    ///
    /// Defensively total: `KVBackendGuardStore.read` already rejects records
    /// with non-finite/out-of-range timestamps as corrupt, but this function
    /// renders whatever record it is HANDED (tests build them directly, and
    /// a future caller may not read through the store), and a diagnostics
    /// formatter that can trap — `Int(1e308)` does — would take down
    /// `status`/`doctor` exactly when they are needed. Clamp to the finite
    /// displayable range instead; ~100,000 years caps any representable age
    /// while staying far inside `Int` (a wrong "d" figure beats a crash).
    static func ageText(record: KVBackendGuard, now: Double) -> String {
        let age = now - record.trippedAt
        let clamped = age.isFinite ? min(max(0, age), 86_400 * 36_500_000) : 0
        let seconds = Int(clamped)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
