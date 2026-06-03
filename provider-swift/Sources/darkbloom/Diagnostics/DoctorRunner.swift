import Foundation
import ProviderCore

/// Builds the operator-facing "why am I / aren't I earning?" diagnosis that
/// `darkbloom doctor` prints, combining local probes (SE key, RAM, hardware),
/// the daemon state file (trust reason, live runtime), and a coordinator
/// version check. Returns sectioned `Diagnostic`s for the renderer.
enum DoctorRunner {
    static func buildOperatorDiagnosis(
        snapshot: RuntimeSnapshot,
        coordinatorURL: String
    ) async -> [Diagnostic] {
        var out: [Diagnostic] = []
        let now = Date().timeIntervalSince1970
        let state = DaemonStateFile.read()
        let daemonUp = state.map { daemonProcessAlive(pid: $0.pid) } ?? false

        // ---- Attestation key (local, no daemon needed) ----
        let se = SEKeySelfTest.run()
        out.append(Diagnostic(section: .attestationKey, name: "se key sign test",
                              level: se.level, message: se.message, fix: se.fix))

        // ---- Coordinator trust (from the daemon's last trust_status) ----
        if let state, let trust = state.trust, daemonUp, !state.isStale(now: now) {
            let advice = TrustReasonCatalog.advice(level: trust.trustLevel, status: trust.status, reason: trust.reason)
            let level = TrustReasonCatalog.level(trustLevel: trust.trustLevel, status: trust.status)
            out.append(Diagnostic(section: .trust, name: "trust level",
                                  level: level,
                                  message: "\(trust.trustLevel) / \(trust.status) — \(advice.message)",
                                  fix: advice.fix))
        } else if daemonUp {
            out.append(Diagnostic(section: .trust, name: "trust level", level: .warn,
                                  message: "the daemon is running but hasn't received a trust status from the coordinator yet (or it's stale).",
                                  fix: "wait ~1 min and re-run `darkbloom doctor`; if it persists, check connectivity below."))
        } else {
            out.append(Diagnostic(section: .trust, name: "trust level", level: .warn,
                                  message: "the provider daemon isn't running, so live trust status is unavailable.",
                                  fix: "run `darkbloom start`, then `darkbloom doctor`."))
        }
        // Enrollment hint (local).
        if !checkMDMEnrolled() {
            out.append(Diagnostic(section: .trust, name: "mdm enrollment", level: .warn,
                                  message: "this Mac is not enrolled in MDM — hardware trust can't be granted, so you won't receive traffic on a hardware-trust network.",
                                  fix: "run `darkbloom enroll` and approve the profile in System Settings → Profiles, then wait ~5 min."))
        }

        // ---- Traffic readiness: does the assigned/configured model fit RAM? ----
        if let hw = snapshot.hardware {
            // Use the SAME accounting the provider enforces at load time
            // (total − reserve − GPU − cache) × 0.7, not the raw available RAM —
            // otherwise doctor reports "fits" for a model the provider refuses.
            // When the daemon is up, subtract its live GPU-active memory.
            let gpuActiveGb = (daemonUp ? state?.capacity?.gpuMemoryActiveGb : nil) ?? 0
            let usableGb = ModelFitDiagnostic.usableInferenceGb(
                totalGb: Double(hw.memoryGb),
                reserveGb: Double(snapshot.config.provider.memoryReserveGB),
                gpuActiveGb: gpuActiveGb)
            let targetID = state?.currentModel ?? snapshot.config.backend.model ?? snapshot.config.backend.enabledModels.first
            let alternatives = snapshot.models.map {
                ModelFitDiagnostic.ModelOption(id: $0.id, weightGb: $0.estimatedMemoryGb)
            }
            if let targetID, let target = snapshot.models.first(where: { $0.id == targetID }) {
                out.append(ModelFitDiagnostic.diagnose(
                    modelID: targetID, weightGb: target.estimatedMemoryGb,
                    usableGb: usableGb, alternatives: alternatives))
            } else if !alternatives.isEmpty {
                // No specific target; check the largest local model fits.
                if let biggest = alternatives.max(by: { $0.weightGb < $1.weightGb }) {
                    out.append(ModelFitDiagnostic.diagnose(
                        modelID: biggest.id, weightGb: biggest.weightGb,
                        usableGb: usableGb, alternatives: alternatives))
                }
            }
        }

        // ---- Runtime (live, from state file) ----
        if let state, daemonUp {
            if state.isStale(now: now) {
                out.append(Diagnostic(section: .runtime, name: "daemon", level: .warn,
                                      message: "running but its last update was \(Int(state.ageSeconds(now: now)))s ago — it may be wedged.",
                                      fix: "check `darkbloom logs`; consider `darkbloom stop && darkbloom start`."))
            } else {
                let model = state.currentModel ?? "none loaded"
                out.append(Diagnostic(section: .runtime, name: "daemon connected", level: .pass,
                                      message: "up \(formatDuration(state.uptimeSeconds(now: now))), model: \(model), \(state.stats.requestsServed) requests served.",
                                      fix: nil))
            }
            if let err = state.lastModelLoadError {
                out.append(Diagnostic(section: .runtime, name: "recent model load", level: .warn,
                                      message: "FAILED for \(err.model): \(err.message)",
                                      fix: "see the model-fit check above; serve a model that fits this box's RAM."))
            }
            // ---- Billing ----
            if state.stats.usageGaps > 0 {
                out.append(Diagnostic(section: .billing, name: "usage reporting", level: .warn,
                                      message: "\(state.stats.usageGaps) completed request(s) had a missing/zero usage chunk (under-counting risk).",
                                      fix: "run `darkbloom report` and include this doctor output."))
            } else {
                out.append(Diagnostic(section: .billing, name: "usage reporting", level: .pass,
                                      message: "\(state.stats.requestsServed) requests / \(state.stats.tokensGenerated) tokens reported this session.",
                                      fix: nil))
            }
        }

        // ---- Version (coordinator) ----
        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)
        switch await updater.checkForUpdate() {
        case .updateAvailable(let current, let latest):
            out.append(VersionDiagnostic.diagnose(current: current, minimum: nil, latest: latest.version))
        case .upToDate(let current):
            out.append(VersionDiagnostic.diagnose(current: current, minimum: nil, latest: current))
        case .checkFailed:
            break // network section already covers coordinator reachability
        }

        return out
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
