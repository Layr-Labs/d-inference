import Foundation
import ProviderCore

/// Operator-facing rendering and diagnosis of per-slot KV-backend and MTP
/// posture (migration plan §16.5).
///
/// WHY THIS EXISTS. The v0.8.0 paged rollout has no canary fleet, and an
/// explicit `engine_v2_kv_backend = "paged"` now REFUSES rather than
/// degrading — a box either serves paged or serves nothing. Until now
/// nothing on the box said which happened: `status` listed warm models and
/// `doctor` checked hardware, neither named a KV backend.
///
/// SOURCE OF TRUTH AND ITS STALENESS. Everything here reads
/// `DaemonState` — the JSON snapshot at `~/.darkbloom/daemon-state.json`
/// that the running daemon rewrites from `capacityRefreshTick` every
/// `max(1, heartbeat_interval_secs / 2)` seconds (≈2 s at the default
/// 5 s heartbeat) and, out of band, the instant a model load fails. The CLI
/// is a separate process with no IPC to the daemon, so this file is the
/// ONLY live source available. It can therefore be stale, and a stale
/// `paged` printed after a reload that fell back is worse than printing
/// nothing: it is a confident liar. Every renderer below carries the
/// snapshot's age, and `KVPostureDiagnosis` withholds the backend verdict
/// entirely once the snapshot is past the wedge bar.
enum KVBackendPosture {
    /// How long a snapshot may go unrefreshed before its live fields are
    /// reported as suspect. Four missed writes, floored at 10 s so a fast
    /// heartbeat cannot make an ordinary CLI round-trip look stale.
    static func staleAfterSeconds(heartbeatIntervalSecs: UInt64) -> Double {
        max(4 * refreshPeriodSeconds(heartbeatIntervalSecs: heartbeatIntervalSecs), 10)
    }

    /// How long a snapshot may go unrefreshed before the daemon is called
    /// WEDGED rather than merely slow. Twice the warning bar — eight missed
    /// writes — floored at the 90 s `DaemonState.isStale` default so an
    /// ordinary fast-heartbeat box keeps exactly the bar it always had.
    /// The derivation only starts to bind above a ~23 s heartbeat, and that
    /// is the whole point: at `heartbeat_interval_secs = 200` the daemon
    /// legitimately rewrites every 100 s, so a fixed 90 s bar would call a
    /// healthy daemon wedged during every normal interval, withhold its
    /// backend verdict, and exit `doctor` non-zero.
    static func wedgedAfterSeconds(heartbeatIntervalSecs: UInt64) -> Double {
        max(8 * refreshPeriodSeconds(heartbeatIntervalSecs: heartbeatIntervalSecs), 90)
    }

    /// The daemon's own write period, for telling an operator what cadence
    /// they should have seen.
    static func refreshPeriodSeconds(heartbeatIntervalSecs: UInt64) -> Double {
        Double(max(1, heartbeatIntervalSecs / 2))
    }

    // MARK: - status rendering

    /// The `darkbloom status` block: a header carrying the snapshot age and
    /// one line per slot. Empty only when there is no state file at all —
    /// the caller has already printed "Daemon: not running" in that case.
    static func statusLines(
        state: DaemonState,
        now: Double,
        heartbeatIntervalSecs: UInt64
    ) -> [String] {
        let age = state.ageSeconds(now: now)
        let staleAfter = staleAfterSeconds(heartbeatIntervalSecs: heartbeatIntervalSecs)
        let period = refreshPeriodSeconds(heartbeatIntervalSecs: heartbeatIntervalSecs)
        let ageText = "\(Int(age.rounded()))s ago"

        guard let slots = state.slots else {
            // nil ⇒ NOT REPORTED. A daemon built before per-slot posture
            // existed. Never render this as "no slots" — the operator would
            // read an unanswered question as an answer.
            return [
                "Slot posture: not reported by this daemon "
                    + "(state written \(ageText); upgrade and restart to see KV backends)"
            ]
        }

        var lines: [String] = []
        if age > staleAfter {
            lines.append(
                "Slot posture: STALE — state written \(ageText), expected every ~\(Int(period))s; "
                    + "the lines below may predate a reload or a failed load")
        } else {
            lines.append("Slot posture: state written \(ageText)")
        }
        if slots.isEmpty {
            lines.append("  (no models loaded)")
            return lines
        }
        for slot in slots {
            lines.append("  " + slotLine(slot))
        }
        return lines
    }

    static func slotLine(_ slot: DaemonState.SlotPosture) -> String {
        // A slot that never built an engine has no MTP posture to report,
        // and "mtp=disabled" on a refused load reads as a configuration
        // choice rather than a consequence of the refusal.
        guard slot.loadError == nil else {
            return "\(slot.model): \(backendPhrase(slot))"
        }
        return "\(slot.model): \(backendPhrase(slot)) | \(mtpPhrase(slot))"
    }

    /// Resolved backend, always paired with the request it was resolved
    /// from — during a staged rollout "paged" alone does not answer whether
    /// this box did what it was told — and with the degrade reason when one
    /// exists, because "contiguous (requested auto)" is expected output for
    /// a veto, the kill switch, the crash-loop guard, AND a real paged
    /// failure alike; only the reason separates them.
    static func backendPhrase(_ slot: DaemonState.SlotPosture) -> String {
        let requested = "requested \(slot.kvBackendRequested)"
        if let error = slot.loadError {
            return "kv=NOT SERVING (\(requested)) — load failed: \(error)"
        }
        guard let resolved = slot.kvBackend else {
            return "kv=unknown (\(requested))"
        }
        guard let reason = slot.kvBackendFallbackReason else {
            return "kv=\(resolved) (\(requested))"
        }
        return "kv=\(resolved) (\(requested) — fallback: \(reason))"
    }

    /// "Enabled" and "producing drafts" are different states, and an inert
    /// slot — drafter resident, zero rounds — looks healthy while emitting
    /// nothing. The reason is always named when MTP is not producing.
    static func mtpPhrase(_ slot: DaemonState.SlotPosture) -> String {
        guard slot.mtpEnabled else { return "mtp=disabled" }
        if slot.mtpActive { return "mtp=enabled, active" }
        let reason = slot.mtpInactiveReason
        if reason == MTPFallbackReason.inertKVUnsupported.rawValue {
            return "mtp=enabled but INERT (\(MTPFallbackReason.inertKVUnsupported.rawValue))"
        }
        return "mtp=enabled but inactive (\(reason ?? "reason unreported"))"
    }
}

/// The operator's CONFIGURED backend selection, as `doctor` reads it out of
/// provider.toml before consulting any daemon.
///
/// Kept distinct from what the slots report because the two answer different
/// questions: config is the INTENT, slots are the EVIDENCE. A staged rollout
/// with intent and no evidence is the case the verdict below must not
/// certify.
struct KVBackendSelection: Equatable {
    /// `[backend] engine_v2_kv_backend`.
    var global: String
    /// `[backend] engine_v2_kv_backend_by_model`.
    var byModel: [String: String]

    static let auto = KVBackendSelection(global: "auto", byModel: [:])

    /// Every non-`auto` selection on record, paired with the model it names —
    /// nil for the box-wide global, which names none. Phrased the way the
    /// operator wrote it so the fix is obvious from the doctor line alone.
    private var explicit: [(phrase: String, model: String?)] {
        var out: [(phrase: String, model: String?)] = []
        if global != "auto" {
            out.append(("engine_v2_kv_backend = \"\(global)\"", nil))
        }
        for (model, backend) in byModel.sorted(by: { $0.key < $1.key }) where backend != "auto" {
            out.append(("\(model) = \"\(backend)\"", model))
        }
        return out
    }

    /// The explicit requests that no slot stands behind, named the same way.
    ///
    /// `proven` is the slot list filtered to slots reporting an explicit
    /// request of their own — the only evidence a CLI has. Presence, not
    /// quality: a slot serving the wrong backend is a mismatch the caller
    /// reports on, whereas a request whose model never loaded has nothing to
    /// report on at all, and that silence is what this catches.
    ///
    /// SCOPE decides which slot may vouch for which request, and conflating
    /// the two is the defect: honouring model B's paged request says nothing
    /// about model A's. A per-model override names its model, so only a slot
    /// for THAT model counts. The global names none — `parseSelection`
    /// resolves `byModel[modelID] ?? global` — so any slot carrying no
    /// override of its own vouches for it. A listed model takes its request
    /// from `byModel` whatever the value there is, which is why the key's
    /// PRESENCE and not its value is what stops that slot from vouching.
    func unprovenRequests(provenBy proven: [DaemonState.SlotPosture]) -> [String] {
        let models = Set(proven.map(\.model))
        return explicit.compactMap { request in
            if let model = request.model {
                return models.contains(model) ? nil : request.phrase
            }
            return proven.contains { byModel[$0.model] == nil } ? nil : request.phrase
        }
    }
}

// MARK: - doctor

/// Pure diagnosis of "is this box serving the KV backend it was told to?",
/// rendered as the same `DoctorCheck` rows the rest of `doctor` prints.
///
/// Two checks, deliberately separate: freshness of the snapshot, and the
/// backend verdict itself. Merging them would let a wedged daemon report a
/// confident backend, which is the failure mode this whole section exists
/// to prevent.
enum KVPostureDiagnosis {
    static func checks(
        state: DaemonState?,
        daemonRunning: Bool,
        now: Double,
        heartbeatIntervalSecs: UInt64,
        configured: KVBackendSelection = .auto
    ) -> [DoctorCheck] {
        guard daemonRunning else {
            // `doctor` already prints "Daemon: NOT running" above; a backend
            // verdict from a dead daemon's last file would be exactly the
            // stale confidence this check exists to prevent.
            return []
        }
        guard let state else {
            return [
                DoctorCheck(
                    name: "kv backend posture",
                    status: .warn,
                    detail: "daemon is running but has written no state file yet; "
                        + "re-run in a few seconds")
            ]
        }

        let age = state.ageSeconds(now: now)
        let staleAfter = KVBackendPosture.staleAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        let period = KVBackendPosture.refreshPeriodSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        let ageText = "\(Int(age.rounded()))s"
        var out: [DoctorCheck] = []

        // Freshness is a fault in its own right: a running daemon that has
        // stopped rewriting its snapshot is wedged, and every live field
        // below it is a guess.
        let wedged = age > KVBackendPosture.wedgedAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        if wedged {
            out.append(
                DoctorCheck(
                    name: "daemon state freshness",
                    status: .fail,
                    detail: "daemon is running but its state file has not been rewritten for "
                        + "\(ageText) (expected every ~\(Int(period))s) — it is wedged; "
                        + "check `darkbloom logs`, then `darkbloom stop && darkbloom start`"))
        } else if age > staleAfter {
            out.append(
                DoctorCheck(
                    name: "daemon state freshness",
                    status: .warn,
                    detail: "state file is \(ageText) old (expected every ~\(Int(period))s)"))
        } else {
            out.append(
                DoctorCheck(
                    name: "daemon state freshness",
                    status: .pass,
                    detail: "state file rewritten \(ageText) ago"))
        }

        if wedged {
            out.append(
                DoctorCheck(
                    name: "kv backend posture",
                    status: .warn,
                    detail: "verdict withheld — the state file is \(ageText) old, so any backend "
                        + "it names may predate a reload"))
            return out
        }

        guard let slots = state.slots else {
            out.append(
                DoctorCheck(
                    name: "kv backend posture",
                    status: .warn,
                    detail: "this daemon does not report per-slot KV posture; "
                        + "upgrade and restart to diagnose a paged rollout"))
            return out
        }

        out.append(backendCheck(slots: slots, configured: configured))
        return out
    }

    /// The verdict: did every EXPLICIT backend request get honoured?
    ///
    /// `auto` is never a failure — it promises nothing, so whichever
    /// backend it lands on is by definition honoured. (It resolves
    /// contiguous as of v0.8.1, so an `auto` slot reporting contiguous is
    /// the expected steady state, not a finding.) An
    /// explicit request is a claim someone verifies against, so a refusal
    /// (no engine built, box serving nothing for that model) and a silent
    /// degrade (kill switch, VLM veto) both FAIL.
    ///
    /// The slots alone cannot answer this, and neither can "SOME slot reports
    /// an explicit backend". Intent is checked per REQUEST, against the slot
    /// that could vouch for that request:
    ///
    ///  - `engine_v2_kv_backend = "paged"` with startup preload off — or
    ///    after an idle unload — leaves `slots: []`. Reading intent solely
    ///    off the slots concludes nobody asked for anything and certifies a
    ///    paged rollout that never loaded a paged engine.
    ///  - With two models explicitly configured and only ONE of them loaded,
    ///    the loaded one makes the slot-derived intent non-empty. Consulting
    ///    `configured` only for an EMPTY slot list then passes the box as
    ///    "every explicit request honoured" while the other model's request
    ///    has no slot behind it at all — the same defect, partially loaded,
    ///    and harder to catch because a genuinely honoured request is what
    ///    does the vouching.
    static func backendCheck(
        slots: [DaemonState.SlotPosture],
        configured: KVBackendSelection = .auto
    ) -> DoctorCheck {
        let explicit = slots.filter { $0.kvBackendRequested != "auto" }
        let unproven = configured.unprovenRequests(provenBy: explicit)
        let summary = slots.isEmpty
            ? "no models loaded"
            : slots.map { "\($0.model)=\($0.kvBackend ?? "none")" }.joined(separator: ", ")

        var failures: [String] = []
        var honoured: [String] = []
        var unknown: [String] = []
        for slot in explicit {
            let want = slot.kvBackendRequested
            if let error = slot.loadError {
                failures.append(
                    "\(slot.model): \(want) requested but REFUSED — no engine was built, this box "
                        + "is serving nothing for that model (\(error))")
            } else if let got = slot.kvBackend {
                if got == want {
                    honoured.append("\(slot.model)=\(got)")
                } else {
                    failures.append(
                        "\(slot.model): \(want) requested but serving \(got)")
                }
            } else {
                unknown.append(slot.model)
            }
        }

        // A refusal outranks an outstanding request: that model is serving
        // nothing, which is both worse and actionable now. The outstanding
        // request rides along rather than waiting for the FAIL to clear.
        if !failures.isEmpty {
            var detail = failures.joined(separator: "; ")
            if !unproven.isEmpty {
                detail += "; config also requests \(unproven.joined(separator: ", ")) "
                    + "with no slot behind it"
            }
            return DoctorCheck(name: "kv backend posture", status: .fail, detail: detail)
        }
        if !unknown.isEmpty {
            return DoctorCheck(
                name: "kv backend posture",
                status: .warn,
                detail: "no resolved backend reported for \(unknown.joined(separator: ", "))")
        }
        guard unproven.isEmpty else {
            return DoctorCheck(
                name: "kv backend posture",
                status: .warn,
                detail: "config requests \(unproven.joined(separator: ", ")) but no slot reports "
                    + "that request (\(summary)) — nothing on this box has loaded, let alone "
                    + "proved, the backend it was configured for")
        }
        if honoured.isEmpty {
            // Nothing explicit anywhere: not in config, not on a slot.
            return DoctorCheck(
                name: "kv backend posture",
                status: .pass,
                detail: "no explicit backend request (auto); \(summary)")
        }
        return DoctorCheck(
            name: "kv backend posture",
            status: .pass,
            detail: "every explicit request honoured: \(honoured.joined(separator: ", "))")
    }
}
