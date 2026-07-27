import Foundation
import ProviderCore

/// Operator-facing rendering of the crash-loop KV-backend guard
/// (`KVBackendGuard`) for `darkbloom status` and `darkbloom doctor`.
///
/// Pure over its inputs (record injected, clock injected) so the wording —
/// which is the operator's ONLY explanation for a box that quietly went
/// contiguous — is pinned by tests rather than eyeballed.
///
/// Two states, rendered differently on purpose:
///
///   * ACTIVE (record version == running version): `.auto` resolves
///     contiguous on this box right now. Always names both exits — the
///     next release, and `darkbloom doctor --clear-backend-guard` — so the
///     line never reads as a permanent verdict.
///   * STALE (version differs): the record is inert (the factory's version
///     check ignores it) and the next daemon start deletes it. Rendered so
///     an operator reading `status` between the release landing and the
///     daemon restarting does not conclude the guard still binds.
enum KVBackendGuardDiagnostics {

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
                "KV-backend guard: ACTIVE — `.auto` serves contiguous on this box "
                    + "(tripped \(ageText(record: record, now: now)) ago on "
                    + "v\(record.providerVersion) after \(record.crashCount) crash-loop "
                    + "restarts; clears on the next release, or now via "
                    + "`darkbloom doctor --clear-backend-guard`)"
            ]
        }
        return [
            "KV-backend guard: stale — tripped on v\(record.providerVersion), this "
                + "binary is v\(runningVersion); inert, removed at next daemon start"
        ]
    }

    /// The `darkbloom doctor` check row. WARN, never FAIL: a guarded box is
    /// SERVING (on contiguous) — degraded posture, not an outage — and
    /// `doctor --strict` still escalates it for operators who want that.
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
            detail: "ACTIVE — `.auto` serves contiguous on this box; tripped "
                + "\(ageText(record: record, now: now)) ago on v\(record.providerVersion) "
                + "after \(record.crashCount) crash-loop restarts. Clears on the next "
                + "release, or run `darkbloom doctor --clear-backend-guard` to retry "
                + "paged now")
    }

    /// Coarse human age ("41s", "12m", "5h", "3d") — the reader needs "how
    /// long has this box been off paged", not a timestamp to subtract.
    static func ageText(record: KVBackendGuard, now: Double) -> String {
        let age = max(0, now - record.trippedAt)
        let seconds = Int(age)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}
