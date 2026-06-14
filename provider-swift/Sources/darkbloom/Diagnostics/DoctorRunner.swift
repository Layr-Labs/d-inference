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
        // "Fresh" = the daemon is running AND its state snapshot isn't stale, so
        // its live fields (trust level, current model, capacity) are trustworthy.
        let stateFresh = daemonUp && !(state?.isStale(now: now) ?? true)

        // ---- Attestation key (local, no daemon needed) ----
        let se = SEKeySelfTest.run()
        out.append(Diagnostic(section: .attestationKey, name: "se key sign test",
                              level: se.level, message: se.message, fix: se.fix))

        // ---- APNs code-identity readiness (local) ----
        // Will this box be able to obtain an APNs token and attest its code
        // identity? Requires a logged-in console (Aqua) session; a missing
        // session, no auto-login, or idle auto-logout each break attestation.
        // Pure verdict logic lives in ProviderCore; here we only feed it the
        // live machine signals.
        out.append(contentsOf: AttestationReadiness.evaluate(
            AttestationReadiness.gather(),
            sleepPrevented: systemSleepPrevented()))

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
        // Enrollment hint (local) — but skip it when the coordinator already
        // grants this provider hardware trust (e.g. via ACME device attestation,
        // which needs no MDM profile). Nagging an already-hardware-trusted box to
        // enroll in MDM is a false warning that sends the operator down the wrong
        // flow and contradicts the trust line printed just above.
        //
        // Otherwise, delegate the verdict to the pure MDMTrustDiagnosis helper,
        // which combines the daemon's last trust level with this Mac's actual MDM
        // enrollment. This is what lets doctor DISTINGUISH "enrolled in Darkbloom
        // MDM but the coordinator's live SecurityInfo check is still pending /
        // timing out" (trust stuck at self_signed) from "not enrolled at all" —
        // the previously-silent stall that left operators thinking they passed
        // while earning nothing.
        let alreadyHardwareTrusted = stateFresh && state?.trust?.trustLevel == "hardware"
        if !alreadyHardwareTrusted {
            let liveTrustLevel = stateFresh ? state?.trust?.trustLevel : nil
            let liveStatus = stateFresh ? state?.trust?.status : nil
            let enrollment = checkMDMEnrollment(coordinatorURL: snapshot.config.coordinator.url)
            if let diag = MDMTrustDiagnosis.diagnose(trustLevel: liveTrustLevel, status: liveStatus, enrollment: enrollment) {
                out.append(diag)
            }
        }

        // ---- Traffic readiness: does the assigned/configured model fit RAM? ----
        if let hw = snapshot.hardware {
            // Mirror the provider's REAL load gate via ModelFitDiagnostic →
            // ModelLoadAdmission: clamp to live OS-available memory and subtract
            // the OS reserve + resident MLX memory, not raw total−reserve —
            // otherwise doctor reports "fits" for a model the provider refuses.
            // When the daemon is up and fresh, subtract its live GPU-active
            // memory too (the min() inside ModelLoadAdmission keeps it conservative
            // without double-counting against the OS-available figure).
            let gpuActiveGb = (stateFresh ? state?.capacity?.gpuMemoryActiveGb : nil) ?? 0
            let gpuCacheGb = (stateFresh ? state?.capacity?.gpuMemoryCacheGb : nil) ?? 0
            let bytesPerGb = 1024.0 * 1024.0 * 1024.0
            let systemAvailableGb = SystemMemory.availableBytes().map { Double($0) / bytesPerGb }
            let usableGb = ModelFitDiagnostic.usableInferenceGb(
                totalGb: Double(hw.memoryGb),
                reserveGb: Double(snapshot.config.provider.memoryReserveGB),
                systemAvailableGb: systemAvailableGb,
                gpuActiveGb: gpuActiveGb,
                gpuCacheGb: gpuCacheGb)

            // Prefer the live loaded model ONLY when the daemon is up and fresh;
            // otherwise diagnose the CONFIGURED model. A stale state file (daemon
            // stopped/crashed, then provider.toml changed to a larger model)
            // would otherwise check last session's model and miss the new misfit.
            let liveModel = stateFresh ? state?.currentModel : nil
            let targetID = liveModel ?? snapshot.config.backend.model ?? snapshot.config.backend.enabledModels.first

            // Use the UNFILTERED model list: ModelScanner.scanModels drops models
            // too large for this box, so a too-large CONFIGURED model would be
            // absent and doctor would silently diagnose a different (fitting) one
            // instead of flagging the one that will never load.
            let allModels = ModelScanner.scanAllModels(hardwareInfo: hw)
            let alternatives = allModels.map {
                ModelFitDiagnostic.ModelOption(id: $0.id, weightGb: $0.estimatedMemoryGb)
            }
            if let targetID, let target = allModels.first(where: { $0.id == targetID }) {
                out.append(ModelFitDiagnostic.diagnose(
                    modelID: targetID, weightGb: target.estimatedMemoryGb,
                    usableGb: usableGb, alternatives: alternatives))
            } else if !alternatives.isEmpty {
                // No specific/known target; check the largest local model fits.
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
                let warm = WarmModelsFormat.warmModelsLine(warmModels: state.warmModels, currentModel: state.currentModel)
                let mru = WarmModelsFormat.mostRecentlyUsedLine(currentModel: state.currentModel)
                out.append(Diagnostic(section: .runtime, name: "daemon connected", level: .pass,
                                      message: "up \(formatDuration(state.uptimeSeconds(now: now))), warm models: \(warm) (\(WarmModelsFormat.mostRecentlyUsedLabel.lowercased()): \(mru)), \(state.stats.requestsServed) requests served.",
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
        // NOTE: `minimum` is nil for now — VersionDiagnostic supports a hard
        // below-minimum FAIL, but the coordinator only exposes
        // min_provider_version on Privy-authenticated /v1/me endpoints, which
        // this device-token CLI can't call. Surfacing it needs a device-authed
        // source (a new endpoint or a trust_status/registration field) — tracked
        // as a follow-up. Below-min providers are still flagged indirectly: the
        // coordinator marks them RuntimeVerified=false and the trust section
        // above reports the resulting "not earning" state.
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

    /// Best-effort read of whether the system is currently being kept awake,
    /// via `pmset -g assertions`. Informational only (the provider
    /// self-caffeinates while serving), so nil/UNKNOWN on any failure is fine.
    private static func systemSleepPrevented() -> Bool? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // `PreventUserIdleSystemSleep` / `PreventSystemSleep` report 1 when an
        // assertion (e.g. caffeinate, an active inference) is holding the system
        // awake. Any "1" on those lines ⇒ sleep currently prevented.
        for line in text.split(separator: "\n") {
            let l = line.lowercased()
            if l.contains("preventuseridlesystemsleep") || l.contains("preventsystemsleep") {
                if l.contains(" 1") || l.hasSuffix("1") { return true }
            }
        }
        return false
    }
}
