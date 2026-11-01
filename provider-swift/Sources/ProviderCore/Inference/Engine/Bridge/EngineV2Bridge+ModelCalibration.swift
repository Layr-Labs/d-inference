import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// Called after slot publication and on capacity ticks, never on scan or
    /// attestation. Ordinary autoregressive and native block engines bootstrap once per loaded
    /// configuration; native MiMo retains its periodic maintenance plan.
    @discardableResult
    func startModelCalibrationIfNeeded(requireNominalPosture: Bool = true,
        now: ContinuousClock.Instant = .now,
        onRetired: (@Sendable () async -> Void)? = nil) -> Bool {
        let continuous = nativeTransactionID != nil
        // Early serving or partial samples must not suppress an unfinished bootstrap.
        let unfinishedBootstrap = !modelCalibration.bootstrapCompleted
        // Bounded probes never qualify a reviewed deadline timing envelope.
        guard ownedEngine is EngineV2 || ownedEngine is CBv2NativeBlockEngine,
            deadlineProfile == nil, canSubmitWithNativeOwner(), !slotPostureClosed,
            continuous || !modelCalibration.bootstrapCompleted,
            !modelCalibration.closed, modelCalibration.task == nil, active.isEmpty, pendingSubmissionIDs.isEmpty,
            modelCalibration.nextAttempt.map({ now >= $0 }) ?? true,
            (!requireNominalPosture || calibrationPosturePermitsWork()),
            unfinishedBootstrap || performanceMeasurements.freshRate("isolated_prefill", now: now,
                maximumAge: ModelCalibrationPolicy.refreshAge) == nil
                || performanceMeasurements.freshRate("decode", now: now,
                    maximumAge: ModelCalibrationPolicy.refreshAge) == nil,
            let serviceBudget else { return false }
        let task = serviceBudget.idleCalibration.startIfIdle(isIdle: { serviceBudget.isIdle },
            onRetired: onRetired) { [weak self] in
            await self?.runModelCalibration(continuous: continuous, requireNominalPosture: requireNominalPosture)
        }
        guard let task else { return false }
        modelCalibration.task = task
        return true
    }

    func runModelCalibration(continuous: Bool, requireNominalPosture: Bool = true) async {
        modelCalibration.interrupted = false
        // Excluded first-use shapes precede the measured cells. Preemption
        // cancels this task, so the loop below stops and the session retries.
        if !continuous { await runShapeWarmupIfNeeded(requireNominalPosture: requireNominalPosture) }
        let cells = continuous
            ? (modelCalibration.bootstrapCompleted ? ModelCalibrationPolicy.maintenance
                : ModelCalibrationPolicy.bootstrap(maximumConcurrency: effectiveServingConcurrency))
            : ModelCalibrationPolicy.startup
        var succeeded = true
        for (index, cell) in cells.enumerated() {
            if Task.isCancelled || modelCalibration.interrupted || !canSubmitWithNativeOwner()
                || serviceBudget?.isIdle != true || (requireNominalPosture && !calibrationPosturePermitsWork()) {
                succeeded = false; break
            }
            guard cell.width <= effectiveServingConcurrency else { continue }
            guard ModelCalibrationPolicy.affordable(cell,
                prefill: performanceMeasurements.freshRate("isolated_prefill"),
                decode: performanceMeasurements.freshRate("decode")) else { continue }
            guard (advertisedContextTokens ?? Int.max) >= cell.promptTokens + cell.outputTokens else { continue }
            do {
                let tokens = try modelCalibrationPrompt(targetTokens: cell.promptTokens, variant: index)
                if await runModelCalibrationCell(cell, tokens: tokens,
                    requireNominalPosture: requireNominalPosture) == .failed { succeeded = false; break }
            } catch { succeeded = false; break }
        }
        let complete = succeeded && performanceMeasurements.freshRate("isolated_prefill") != nil
            && performanceMeasurements.freshRate("decode") != nil
        if complete { modelCalibration.bootstrapCompleted = true }
        let delay = Task.isCancelled || modelCalibration.interrupted
            ? ModelCalibrationPolicy.interruptionBackoff
            : complete ? ModelCalibrationPolicy.refreshAge : ModelCalibrationPolicy.failureBackoff
        modelCalibration.nextAttempt = ContinuousClock.now.advanced(by: delay)
        modelCalibration.task = nil
        performanceUpdates?.notify()
    }

    func cancelModelCalibration() -> Task<Void, Never>? {
        modelCalibration.closed = true
        let task = modelCalibration.task
        task?.cancel()
        return task
    }

    func stopModelCalibration() async {
        await cancelModelCalibration()?.value
    }
}
