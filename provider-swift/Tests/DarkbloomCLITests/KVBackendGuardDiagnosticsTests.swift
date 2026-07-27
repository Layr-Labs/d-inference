import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// The crash-loop KV-backend guard's operator-facing surface: what `status`
/// prints, what `doctor` warns on, and how a degrade reason renders in the
/// per-slot posture line. The wording is the operator's ONLY explanation for
/// a box that quietly went contiguous, so it is pinned, not eyeballed.
@Suite("kv backend crash-loop guard (status + doctor rendering)")
struct KVBackendGuardDiagnosticsTests {

    private let active = KVBackendGuard(
        trippedAt: 1_000, providerVersion: "0.8.0", crashCount: 3)

    // MARK: - status line

    @Test("no record prints nothing — the healthy fleet gets no extra line")
    func noRecordPrintsNothing() {
        #expect(KVBackendGuardDiagnostics.statusLines(
            record: nil, now: 2_000, runningVersion: "0.8.0").isEmpty)
    }

    @Test("an active guard names the effect, the age, the version, and BOTH exits")
    func activeGuardLine() {
        let lines = KVBackendGuardDiagnostics.statusLines(
            record: active, now: 1_000 + 7_200, runningVersion: "0.8.0")
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.contains("ACTIVE"))
        #expect(line.contains("`.auto` serves contiguous"))
        #expect(line.contains("2h ago"))
        #expect(line.contains("v0.8.0"))
        #expect(line.contains("3 crash-loop restarts"))
        // Both exits, always: the automatic one and the manual one. A line
        // naming neither reads as a permanent verdict.
        #expect(line.contains("next release"))
        #expect(line.contains("darkbloom doctor --clear-backend-guard"))
    }

    @Test("a version-mismatched record renders as stale/inert, not as active")
    func staleGuardLine() {
        let lines = KVBackendGuardDiagnostics.statusLines(
            record: active, now: 2_000, runningVersion: "0.8.1")
        #expect(lines.count == 1)
        #expect(lines[0].contains("stale"))
        #expect(lines[0].contains("v0.8.0"))
        #expect(lines[0].contains("v0.8.1"))
        #expect(!lines[0].contains("ACTIVE"))
    }

    // MARK: - doctor check

    @Test("doctor reports an active guard as WARN — the box is serving, degraded")
    func doctorWarnsOnActiveGuard() {
        let check = KVBackendGuardDiagnostics.doctorCheck(
            record: active, now: 2_000, runningVersion: "0.8.0")
        #expect(check.name == "kv backend crash-loop guard")
        #expect(check.status == .warn)
        #expect(check.detail.contains("ACTIVE"))
        #expect(check.detail.contains("--clear-backend-guard"))
    }

    @Test("doctor reports a stale guard as inert")
    func doctorReportsStaleGuard() {
        let check = KVBackendGuardDiagnostics.doctorCheck(
            record: active, now: 2_000, runningVersion: "0.8.1")
        #expect(check.status == .warn)
        #expect(check.detail.contains("stale"))
        #expect(check.detail.contains("inert"))
    }

    // MARK: - age formatting

    @Test("age renders in the coarsest useful unit")
    func ageFormatting() {
        func age(_ delta: Double) -> String {
            KVBackendGuardDiagnostics.ageText(
                record: KVBackendGuard(
                    trippedAt: 10_000, providerVersion: "x", crashCount: 3),
                now: 10_000 + delta)
        }
        #expect(age(41) == "41s")
        #expect(age(59) == "59s")
        #expect(age(60) == "1m")
        #expect(age(3_599) == "59m")
        #expect(age(3_600) == "1h")
        #expect(age(86_400 * 3) == "3d")
        // A clock that moved backwards must not print a negative age.
        #expect(age(-50) == "0s")
    }

    @Test("hostile timestamps render a clamped age — never an Int() trap")
    func hostileTimestampsClamp() {
        // `KVBackendGuardStore.read` rejects these as corrupt, but the
        // formatter must be total over whatever record it is handed:
        // `Int(1e308)` traps, and a crashing `status`/`doctor` is the worst
        // possible failure mode for a diagnostics line.
        func render(trippedAt: Double, now: Double = 10_000) -> String {
            KVBackendGuardDiagnostics.ageText(
                record: KVBackendGuard(
                    trippedAt: trippedAt, providerVersion: "x", crashCount: 3),
                now: now)
        }
        #expect(render(trippedAt: -1e308).hasSuffix("d"), "huge age clamps to days")
        #expect(render(trippedAt: 1e308) == "0s", "future timestamp clamps to zero")
        // Non-finite inputs make the AGE non-finite; the formatter renders
        // zero rather than guessing a direction.
        #expect(render(trippedAt: .nan) == "0s")
        #expect(render(trippedAt: -.infinity) == "0s")
        #expect(render(trippedAt: .infinity) == "0s")
    }

    // MARK: - per-slot posture rendering of the degrade reason

    @Test("a degraded slot's posture line carries the fallback reason")
    func postureLineCarriesFallbackReason() {
        let phrase = KVBackendPosture.backendPhrase(
            .init(
                model: "gemma-4-26b",
                kvBackend: "contiguous",
                kvBackendRequested: "auto",
                kvBackendFallbackReason: "crash_loop_guard"))
        #expect(phrase == "kv=contiguous (requested auto — fallback: crash_loop_guard)")
    }

    @Test("an undegraded slot's posture line is unchanged — no reason, no tail")
    func postureLineWithoutReasonUnchanged() {
        let phrase = KVBackendPosture.backendPhrase(
            .init(
                model: "gpt-oss-20b",
                kvBackend: "paged",
                kvBackendRequested: "auto"))
        #expect(phrase == "kv=paged (requested auto)")
    }
}
