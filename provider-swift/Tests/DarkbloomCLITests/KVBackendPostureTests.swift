import Foundation
import ProviderCore
import Testing
@testable import darkbloom

/// §16.5 — an operator on a canary-less box asking "is this machine on
/// paged?" must be able to answer it from the machine. These cover the two
/// halves: what `status` prints, and what `doctor` fails on.
@Suite("kv backend posture (status + doctor)")
struct KVBackendPostureTests {
    /// Default provider heartbeat. The daemon rewrites its state file every
    /// `heartbeat / 2` s, so this is what "fresh" is measured against.
    private let heartbeat: UInt64 = 5

    private func state(
        writtenAt: Double = 1000,
        slots: [DaemonState.SlotPosture]?
    ) -> DaemonState {
        DaemonState(
            pid: 4711, version: "0.8.0", writtenAt: writtenAt, startedAt: 900,
            warmModels: slots?.map(\.model) ?? [], slots: slots)
    }

    private func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
        checks.first { $0.name == name }
    }

    // MARK: - status

    @Test("status names the resolved backend for paged, contiguous, and failed slots")
    func statusReportsBackendPerSlot() {
        let lines = KVBackendPosture.statusLines(
            state: state(slots: [
                .init(
                    model: "gemma-4-26b", kvBackend: "paged", kvBackendRequested: "paged",
                    mtpEnabled: true, mtpActive: true),
                .init(
                    model: "gpt-oss-20b", kvBackend: "contiguous", kvBackendRequested: "auto"),
                .init(
                    model: "big-model", kvBackend: nil, kvBackendRequested: "paged",
                    loadError: "engine_v2: paged KV backend explicitly requested but "
                        + "unavailable — kernel preflight failed"),
            ]),
            now: 1002,
            heartbeatIntervalSecs: heartbeat)
        let text = lines.joined(separator: "\n")

        #expect(text.contains("gemma-4-26b: kv=paged (requested paged)"))
        #expect(text.contains("gpt-oss-20b: kv=contiguous (requested auto)"))
        // The refused slot must never be rendered with a backend it does not
        // have — the operator is deciding whether this box serves paged.
        #expect(text.contains("big-model: kv=NOT SERVING (requested paged)"))
        #expect(text.contains("kernel preflight failed"))
        #expect(!text.contains("big-model: kv=contiguous"))
        #expect(!text.contains("big-model: kv=paged ("))
    }

    @Test("status separates MTP enabled-and-active from enabled-but-inert and names the reason")
    func statusDistinguishesInertMTP() {
        let lines = KVBackendPosture.statusLines(
            state: state(slots: [
                .init(
                    model: "active-slot", kvBackend: "contiguous", kvBackendRequested: "auto",
                    mtpEnabled: true, mtpActive: true),
                .init(
                    model: "inert-slot", kvBackend: "paged", kvBackendRequested: "paged",
                    mtpEnabled: true, mtpActive: false,
                    mtpInactiveReason: MTPFallbackReason.inertKVUnsupported.rawValue),
                .init(
                    model: "off-slot", kvBackend: "contiguous", kvBackendRequested: "auto",
                    mtpEnabled: false, mtpActive: false),
            ]),
            now: 1002,
            heartbeatIntervalSecs: heartbeat)
        let text = lines.joined(separator: "\n")

        #expect(text.contains("active-slot: kv=contiguous (requested auto) | mtp=enabled, active"))
        // The whole point: enabled and inert is NOT the same state as
        // enabled and active, and the reason must be on the line.
        #expect(
            text.contains(
                "inert-slot: kv=paged (requested paged) | mtp=enabled but INERT "
                    + "(inert_kv_unsupported)"))
        #expect(text.contains("off-slot: kv=contiguous (requested auto) | mtp=disabled"))
    }

    @Test("status labels an unexplained inactive MTP slot rather than implying it is off")
    func statusNamesMissingInactiveReason() {
        let lines = KVBackendPosture.statusLines(
            state: state(slots: [
                .init(
                    model: "m", kvBackend: "paged", kvBackendRequested: "paged",
                    mtpEnabled: true, mtpActive: false, mtpInactiveReason: nil)
            ]),
            now: 1000,
            heartbeatIntervalSecs: heartbeat)
        #expect(lines.joined().contains("mtp=enabled but inactive (reason unreported)"))
        #expect(!lines.joined().contains("mtp=disabled"))
    }

    @Test("status carries the snapshot age and shouts when it stopped being refreshed")
    func statusSurfacesStaleness() {
        let slots: [DaemonState.SlotPosture] = [
            .init(model: "m", kvBackend: "paged", kvBackendRequested: "paged")
        ]
        let fresh = KVBackendPosture.statusLines(
            state: state(slots: slots), now: 1003, heartbeatIntervalSecs: heartbeat)
        #expect(fresh[0] == "Slot posture: state written 3s ago")
        #expect(!fresh[0].contains("STALE"))

        // Past four missed writes the value may predate a reload that fell
        // back, and a confidently wrong "paged" is worse than silence.
        let stale = KVBackendPosture.statusLines(
            state: state(slots: slots), now: 1400, heartbeatIntervalSecs: heartbeat)
        #expect(stale[0].contains("STALE"))
        #expect(stale[0].contains("400s ago"))
        #expect(stale[0].contains("expected every ~2s"))
    }

    @Test("status reports an old daemon as not-reported, never as no slots")
    func statusDistinguishesUnreportedFromEmpty() {
        let unreported = KVBackendPosture.statusLines(
            state: state(slots: nil), now: 1001, heartbeatIntervalSecs: heartbeat)
        #expect(unreported.joined().contains("not reported by this daemon"))

        let empty = KVBackendPosture.statusLines(
            state: state(slots: []), now: 1001, heartbeatIntervalSecs: heartbeat)
        #expect(empty.joined().contains("(no models loaded)"))
    }

    // MARK: - doctor

    @Test("doctor FAILS when an explicit paged request was refused")
    func doctorFailsOnRefusedPagedRequest() {
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(
                    model: "gemma-4-26b", kvBackend: nil, kvBackendRequested: "paged",
                    loadError: "engine_v2: paged KV backend explicitly requested but "
                        + "unavailable — kernel preflight failed")
            ]),
            daemonRunning: true,
            now: 1002,
            heartbeatIntervalSecs: heartbeat)

        let verdict = check(checks, "kv backend posture")
        #expect(verdict?.status == .fail)
        #expect(verdict?.detail.contains("gemma-4-26b") == true)
        #expect(verdict?.detail.contains("REFUSED") == true)
        #expect(verdict?.detail.contains("serving nothing for that model") == true)
        #expect(verdict?.detail.contains("kernel preflight failed") == true)
    }

    @Test("doctor FAILS when an explicit paged request silently degraded to contiguous")
    func doctorFailsOnSilentDegrade() {
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(
                    model: "gemma-4-26b", kvBackend: "contiguous", kvBackendRequested: "paged")
            ]),
            daemonRunning: true,
            now: 1002,
            heartbeatIntervalSecs: heartbeat)
        let verdict = check(checks, "kv backend posture")
        #expect(verdict?.status == .fail)
        #expect(verdict?.detail.contains("paged requested but serving contiguous") == true)
    }

    @Test("doctor passes an honoured explicit request and never fails plain auto")
    func doctorPassesHonouredRequests() {
        let honoured = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(model: "gemma-4-26b", kvBackend: "paged", kvBackendRequested: "paged")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat)
        #expect(check(honoured, "kv backend posture")?.status == .pass)

        // auto resolving to contiguous is the DESIGNED outcome, not a fault.
        let auto = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(model: "gemma-4-26b", kvBackend: "contiguous", kvBackendRequested: "auto")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat)
        #expect(check(auto, "kv backend posture")?.status == .pass)
    }

    @Test("doctor warns when paged is requested but nothing is loaded to prove it")
    func doctorWarnsOnUnprovenRequest() {
        // Refusal-on-failure means "requested paged, nothing loaded" is
        // exactly the shape of a rollout that never got off the ground.
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(model: "m", kvBackend: nil, kvBackendRequested: "paged")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat)
        #expect(check(checks, "kv backend posture")?.status == .warn)
    }

    @Test("doctor treats a daemon that stopped rewriting its state as its own fault")
    func doctorFailsOnWedgedStateFile() {
        let slots: [DaemonState.SlotPosture] = [
            .init(model: "m", kvBackend: "paged", kvBackendRequested: "paged")
        ]
        let fresh = KVPostureDiagnosis.checks(
            state: state(slots: slots), daemonRunning: true, now: 1002,
            heartbeatIntervalSecs: heartbeat)
        #expect(check(fresh, "daemon state freshness")?.status == .pass)

        let drifting = KVPostureDiagnosis.checks(
            state: state(slots: slots), daemonRunning: true, now: 1030,
            heartbeatIntervalSecs: heartbeat)
        #expect(check(drifting, "daemon state freshness")?.status == .warn)
        #expect(check(drifting, "kv backend posture")?.status == .pass)

        // Past the wedge bar the snapshot is not evidence any more: the
        // freshness check fails and the backend verdict is WITHHELD rather
        // than asserting a backend that may predate a reload.
        let wedged = KVPostureDiagnosis.checks(
            state: state(slots: slots), daemonRunning: true, now: 1200,
            heartbeatIntervalSecs: heartbeat)
        #expect(check(wedged, "daemon state freshness")?.status == .fail)
        #expect(check(wedged, "daemon state freshness")?.detail.contains("wedged") == true)
        let verdict = check(wedged, "kv backend posture")
        #expect(verdict?.status == .warn)
        #expect(verdict?.detail.contains("verdict withheld") == true)
        #expect(verdict?.detail.contains("paged") == false, "must not assert a stale backend")
    }

    @Test("doctor stays silent about backends when the daemon is down")
    func doctorSkipsWhenDaemonDown() {
        // The last file a dead daemon wrote is precisely the stale
        // confidence these checks exist to prevent; `doctor` already prints
        // "Daemon: NOT running" on its own line.
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(model: "m", kvBackend: "paged", kvBackendRequested: "paged")
            ]),
            daemonRunning: false, now: 1002, heartbeatIntervalSecs: heartbeat)
        #expect(checks.isEmpty)
    }

    @Test("doctor warns rather than passing when a daemon reports no posture at all")
    func doctorWarnsOnUnreportedPosture() {
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: nil), daemonRunning: true, now: 1002,
            heartbeatIntervalSecs: heartbeat)
        #expect(check(checks, "kv backend posture")?.status == .warn)
        #expect(check(checks, "kv backend posture")?.detail
            .contains("does not report per-slot KV posture") == true)

        let noFile = KVPostureDiagnosis.checks(
            state: nil, daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat)
        #expect(check(noFile, "kv backend posture")?.status == .warn)
    }

    @Test("doctor WARNS on an explicit config selection that has no slot behind it")
    func doctorWarnsOnConfiguredBackendWithNoSlots() {
        // The operator surface's worst outcome: `engine_v2_kv_backend =
        // "paged"` box-wide, startup preload off (or an idle unload), so the
        // state file carries `slots: []`. Reading intent off the slots alone
        // concludes nobody asked for anything and PASSES — certifying a
        // paged rollout that never loaded, let alone proved, a paged engine.
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: []),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: KVBackendSelection(global: "paged", byModel: [:]))
        let verdict = check(checks, "kv backend posture")
        #expect(verdict?.status == .warn)
        #expect(verdict?.detail.contains("engine_v2_kv_backend = \"paged\"") == true)
        #expect(verdict?.detail.contains("no models loaded") == true)

        // A per-model override is just as explicit and must not be lost either.
        let byModel = KVPostureDiagnosis.checks(
            state: state(slots: []),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: KVBackendSelection(global: "auto", byModel: ["gemma-4-26b": "paged"]))
        #expect(check(byModel, "kv backend posture")?.status == .warn)
        #expect(check(byModel, "kv backend posture")?.detail
            .contains("gemma-4-26b = \"paged\"") == true)

        // Genuinely-auto config with nothing loaded is still a PASS: there is
        // no claim outstanding for the box to have failed.
        let auto = KVPostureDiagnosis.checks(
            state: state(slots: []),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: .auto)
        #expect(check(auto, "kv backend posture")?.status == .pass)
        #expect(check(auto, "kv backend posture")?.detail
            .contains("no explicit backend request (auto)") == true)
    }

    @Test("doctor WARNS on an explicit request whose model never loaded, even when another's did")
    func doctorWarnsOnPartiallyLoadedExplicitRequests() {
        // The `slots: []` defect in its partially-loaded shape. Two models
        // are explicitly configured paged; only B ever loaded. B's slot makes
        // the slot-derived intent non-empty, so the configured intent was
        // never consulted and the verdict PASSED — "every explicit request
        // honoured" — while A's paged request has no slot behind it at all.
        // An honoured request for one model is not evidence about another.
        let checks = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(model: "b-model", kvBackend: "paged", kvBackendRequested: "paged")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: KVBackendSelection(
                global: "auto", byModel: ["a-model": "paged", "b-model": "paged"]))
        let verdict = check(checks, "kv backend posture")
        #expect(verdict?.status == .warn)
        #expect(verdict?.detail.contains("a-model = \"paged\"") == true)
        // Only the unproven request is named as the problem; B is fine, and
        // naming it would send the operator after a model that is serving.
        #expect(verdict?.detail.contains("b-model = \"paged\"") == false)

        // Scope decides who can vouch for whom. A box-wide explicit request
        // is honoured by any slot that carries no override of its own, so
        // this one is proven and PASSES...
        let globalProven = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(model: "b-model", kvBackend: "paged", kvBackendRequested: "paged")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: KVBackendSelection(global: "paged", byModel: [:]))
        #expect(check(globalProven, "kv backend posture")?.status == .pass)

        // ...whereas the only loaded slot taking its request from its OWN
        // override says nothing about the box-wide one, which is then still
        // outstanding.
        let globalUnproven = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(
                    model: "b-model", kvBackend: "contiguous", kvBackendRequested: "contiguous")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: KVBackendSelection(
                global: "paged", byModel: ["b-model": "contiguous"]))
        let scoped = check(globalUnproven, "kv backend posture")
        #expect(scoped?.status == .warn)
        #expect(scoped?.detail.contains("engine_v2_kv_backend = \"paged\"") == true)

        // A refusal still outranks an unproven request: the box is serving
        // nothing for that model, which is the more urgent fault, and the
        // outstanding request is carried along rather than dropped.
        let refused = KVPostureDiagnosis.checks(
            state: state(slots: [
                .init(
                    model: "b-model", kvBackend: nil, kvBackendRequested: "paged",
                    loadError: "kernel preflight failed")
            ]),
            daemonRunning: true, now: 1002, heartbeatIntervalSecs: heartbeat,
            configured: KVBackendSelection(
                global: "auto", byModel: ["a-model": "paged", "b-model": "paged"]))
        let refusedVerdict = check(refused, "kv backend posture")
        #expect(refusedVerdict?.status == .fail)
        #expect(refusedVerdict?.detail.contains("REFUSED") == true)
        #expect(refusedVerdict?.detail.contains("a-model = \"paged\"") == true)
    }

    @Test("doctor sizes the wedge bar off the configured heartbeat, not a fixed 90s")
    func doctorWedgeBarFollowsConfiguredHeartbeat() {
        let slots: [DaemonState.SlotPosture] = [
            .init(model: "m", kvBackend: "paged", kvBackendRequested: "paged")
        ]
        // heartbeat 200s => the daemon legitimately rewrites every 100s, so a
        // 150s-old snapshot is one ordinary interval, not a wedge. Under the
        // fixed 90s default this FAILED and withheld the backend verdict.
        let slowHeartbeat = KVPostureDiagnosis.checks(
            state: state(slots: slots), daemonRunning: true, now: 1150,
            heartbeatIntervalSecs: 200)
        #expect(check(slowHeartbeat, "daemon state freshness")?.status != .fail)
        #expect(check(slowHeartbeat, "kv backend posture")?.status == .pass)

        // Eight missed writes on the same heartbeat IS a wedge.
        let reallyWedged = KVPostureDiagnosis.checks(
            state: state(slots: slots), daemonRunning: true, now: 1900,
            heartbeatIntervalSecs: 200)
        #expect(check(reallyWedged, "daemon state freshness")?.status == .fail)
        #expect(check(reallyWedged, "kv backend posture")?.detail
            .contains("verdict withheld") == true)

        // A fast heartbeat keeps the historical 90s bar exactly.
        #expect(KVBackendPosture.wedgedAfterSeconds(heartbeatIntervalSecs: heartbeat) == 90)
        #expect(KVBackendPosture.wedgedAfterSeconds(heartbeatIntervalSecs: 200) == 800)
    }
}
