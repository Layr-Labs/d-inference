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
}
