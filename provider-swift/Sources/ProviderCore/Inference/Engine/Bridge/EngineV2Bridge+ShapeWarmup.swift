import Foundation
import Logging
import MLXLMCommon

extension EngineV2Bridge {
    private static let shapeWarmupLogger = Logger(label: "darkbloom.ShapeWarmup")

    var shapeWarmupMode: ModelCalibrationPolicy.ShapeWarmupMode {
        modelCalibration.shapeWarmupModeOverride ?? ModelCalibrationPolicy.shapeWarmupMode()
    }

    /// Ordinary engines only; MiMo-native and block engines keep their own bootstraps.
    var shapeWarmupDue: Bool {
        ownedEngine is EngineV2 && nativeTransactionID == nil
            && !modelCalibration.shapeWarmupCompleted && shapeWarmupMode != .off
    }

    /// A warmup-only session for slots that do not calibrate (standalone serving
    /// or a reviewed deadline profile). Same idle gate, Mac-wide session and
    /// foreground preemption as `startModelCalibrationIfNeeded`.
    @discardableResult
    func startShapeWarmupIfNeeded(requireNominalPosture: Bool = true, grace: Bool = true,
        now: ContinuousClock.Instant = .now,
        onRetired: (@Sendable () async -> Void)? = nil) -> Bool {
        guard shapeWarmupDue, canSubmitWithNativeOwner(), !slotPostureClosed,
            !modelCalibration.closed, modelCalibration.task == nil, active.isEmpty,
            pendingSubmissionIDs.isEmpty, modelCalibration.nextAttempt.map({ now >= $0 }) ?? true,
            !requireNominalPosture || calibrationPosturePermitsWork(),
            let serviceBudget else { return false }
        let task = serviceBudget.idleCalibration.startIfIdle(isIdle: { serviceBudget.isIdle },
            onRetired: onRetired) { [weak self] in
            await self?.runShapeWarmupSession(requireNominalPosture: requireNominalPosture, grace: grace)
        }
        guard let task else { return false }
        modelCalibration.task = task
        return true
    }

    /// Startup preload, before the provider registers or the local listener
    /// opens: the same session, awaited, so the first routed prompt finds its
    /// kernels compiled. It measures nothing, so posture does not gate it.
    /// Cancelling the caller cancels the session.
    func runShapeWarmupBeforeServing() async {
        // The self-test's pump releases its service charge after its stream ends.
        let settle = ContinuousClock.now.advanced(by: ModelCalibrationPolicy.shapeWarmupSettle)
        while shapeWarmupDue, !Task.isCancelled, ContinuousClock.now < settle,
            !(active.isEmpty && pendingSubmissionIDs.isEmpty && serviceBudget?.isIdle == true) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled, startShapeWarmupIfNeeded(requireNominalPosture: false, grace: false),
            let task = modelCalibration.task else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func runShapeWarmupSession(requireNominalPosture: Bool, grace: Bool) async {
        modelCalibration.interrupted = false
        await runShapeWarmupIfNeeded(requireNominalPosture: requireNominalPosture, grace: grace)
        if !modelCalibration.shapeWarmupCompleted {
            modelCalibration.nextAttempt = ContinuousClock.now.advanced(by: ModelCalibrationPolicy.interruptionBackoff)
        }
        modelCalibration.task = nil
    }

    /// Runs the excluded shape cells once per loaded engine when the shader
    /// cache probe finds first-use compiles (or `always`). Only a session the
    /// Mac could not keep (foreground arrival, other work, posture, owner)
    /// leaves the warmup due; its compiled kernels persist, so a retry resumes
    /// after the probes and cells it finished. A timeout or refusal completes
    /// the attempt so a slow Mac never repeats it. Every cell is `warmup`, so
    /// no rate, bucket or counter moves.
    func runShapeWarmupIfNeeded(requireNominalPosture: Bool, grace: Bool = true) async {
        guard shapeWarmupDue else { return }
        modelCalibration.shapeWarmupAttempts += 1
        if grace {
            try? await Task.sleep(nanoseconds: UInt64(ModelCalibrationPolicy.shapeWarmupGraceSeconds * 1_000_000_000))
        }
        let runtime = deadlineRuntimeConfiguration
        let context = [advertisedContextTokens, runtime?.configuredContextTokens].compactMap { $0 }.min()
        let cells = ModelCalibrationPolicy.shapeWarmup(stripeTokens: runtime?.soloPrefillStripeTokens,
            chunkTokens: runtime?.prefillChunkSize ?? 512, width: effectiveServingConcurrency,
            contextTokens: context)
        if shapeWarmupMode == .always { modelCalibration.shaderCacheCold = true }
        let clock = ContinuousClock()
        let started = clock.now
        var outcome = "complete"
        var preemption: String?
        // Each pass runs the next due step: probes until the cache is judged, then cells.
        while true {
            let index = modelCalibration.shapeWarmupCellsCompleted
            guard index < cells.count else { break }
            let probing = modelCalibration.shaderCacheCold == nil
            guard probing || modelCalibration.shaderCacheCold == true else {
                outcome = "skipped (warm shader cache)"; break
            }
            let cell = probing ? ModelCalibrationPolicy.shaderCacheProbe : cells[index]
            preemption = shapeWarmupPreemption(requireNominalPosture: requireNominalPosture)
            if preemption != nil { break }
            let remaining = ModelCalibrationPolicy.shapeWarmupBudgetSeconds
                - WedgeMonitor.seconds(clock.now - started)
            guard remaining >= 1 else { outcome = "budget"; break }
            // Both probes render one prompt, so the repeat has the first run's shapes.
            guard let tokens = try? modelCalibrationPrompt(targetTokens: cell.promptTokens,
                variant: probing ? cells.count : index) else { outcome = "refused"; break }
            let stepStarted = clock.now
            if await runModelCalibrationCell(cell, tokens: tokens,
                requireNominalPosture: requireNominalPosture, timeoutSeconds: remaining) {
                if probing { recordShaderCacheProbe(clock.now - stepStarted) }
                else { modelCalibration.shapeWarmupCellsCompleted = index + 1 }
                continue
            }
            // A partial first probe may have compiled kernels the repeat would reuse.
            if probing, modelCalibration.shaderCacheProbe.isEmpty { modelCalibration.shaderCacheCold = true }
            preemption = shapeWarmupPreemption(requireNominalPosture: requireNominalPosture, requireIdle: false)
            outcome = modelCalibration.interrupted ? "budget" : "refused"
            break
        }
        if preemption == nil {
            modelCalibration.shapeWarmupCompleted = true
            // A cell timer marks the session interrupted; the measured cells still run.
            modelCalibration.interrupted = false
        }
        let elapsedMs = Int((WedgeMonitor.seconds(clock.now - started) * 1_000).rounded())
        let finished = min(modelCalibration.shapeWarmupCellsCompleted, cells.count)
        let summary = preemption.map { "preempted (\($0))" } ?? outcome
        let probe = modelCalibration.shaderCacheProbe.map {
            String(Int((WedgeMonitor.seconds($0) * 1_000).rounded()))
        }
        let detail = "attempt \(modelCalibration.shapeWarmupAttempts)"
            + (probe.isEmpty ? "" : ", probe \(probe.joined(separator: "/")) ms")
        Self.shapeWarmupLogger.info(
            "Shape warmup \(modelId): \(summary) \(finished)/\(cells.count) cells in \(elapsedMs) ms (\(detail))")
    }

    private func recordShaderCacheProbe(_ took: Duration) {
        modelCalibration.shaderCacheProbe.append(took)
        let runs = modelCalibration.shaderCacheProbe
        guard runs.count == 2 else { return }
        modelCalibration.shaderCacheCold = ModelCalibrationPolicy.shaderCacheLooksCold(
            first: runs[0], repeated: runs[1])
    }

    /// What took the Mac back from this attempt, if anything. Only these leave
    /// the warmup due; between cells the Mac must also still be idle.
    private func shapeWarmupPreemption(requireNominalPosture: Bool, requireIdle: Bool = true) -> String? {
        if Task.isCancelled { return serviceBudget?.idleCalibration.cancellationSource ?? "shutdown" }
        if !canSubmitWithNativeOwner() { return "owner" }
        if requireIdle, serviceBudget?.isIdle != true { return "busy" }
        if requireNominalPosture, !calibrationPosturePermitsWork() { return "posture" }
        return nil
    }
}
