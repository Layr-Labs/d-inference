import Foundation

extension EngineV2Bridge {
    /// Called after slot publication and on capacity ticks, never on scan or
    /// attestation. A new bridge binds observations to the loaded configuration.
    @discardableResult
    func startMimoCalibrationIfNeeded(requireNativeMiMo: Bool = true,
        now: ContinuousClock.Instant = .now) -> Bool {
        guard (!requireNativeMiMo || nativeTransactionID != nil),
            supportsPrefillRecoveryRetirement, canSubmitWithNativeOwner(),
            deadlineProfile == nil, !slotPostureClosed,
            !mimoCalibration.closed, mimoCalibration.task == nil, active.isEmpty, pendingSubmissionIDs.isEmpty,
            mimoCalibration.nextAttempt.map({ now >= $0 }) ?? true,
            (!requireNativeMiMo || (!ProcessInfo.processInfo.isLowPowerModeEnabled
                && ProcessInfo.processInfo.thermalState == .nominal)),
            performanceMeasurements.freshRate("isolated_prefill", now: now,
                maximumAge: MimoCalibrationPolicy.refreshAge) == nil
                || performanceMeasurements.freshRate("decode", now: now,
                    maximumAge: MimoCalibrationPolicy.refreshAge) == nil,
            let serviceBudget else { return false }
        let task = serviceBudget.idleCalibration.startIfIdle(isIdle: { serviceBudget.isIdle }) { [weak self] in
            await self?.runMimoCalibration(requireNominalPosture: requireNativeMiMo)
        }
        guard let task else { return false }
        mimoCalibration.task = task
        return true
    }

    func runMimoCalibration(requireNominalPosture: Bool = true) async {
        mimoCalibration.interrupted = false
        let cells = mimoCalibration.bootstrapCompleted ? MimoCalibrationPolicy.maintenance
            : MimoCalibrationPolicy.bootstrap(maximumConcurrency: effectiveServingConcurrency)
        var succeeded = true
        for (index, cell) in cells.enumerated() {
            if Task.isCancelled || mimoCalibration.interrupted || !canSubmitWithNativeOwner()
                || serviceBudget?.isIdle != true || (requireNominalPosture &&
                    (ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState != .nominal)) {
                succeeded = false; break
            }
            guard cell.width <= effectiveServingConcurrency else { continue }
            guard MimoCalibrationPolicy.affordable(cell,
                prefill: performanceMeasurements.freshRate("isolated_prefill"),
                decode: performanceMeasurements.freshRate("decode")) else { continue }
            guard (advertisedContextTokens ?? Int.max) >= cell.promptTokens + cell.outputTokens else { continue }
            do {
                let tokens = try mimoCalibrationPrompt(targetTokens: cell.promptTokens, variant: index)
                if !(await runMimoCalibrationCell(cell, tokens: tokens)) { succeeded = false; break }
            } catch { succeeded = false; break }
        }
        let complete = succeeded && performanceMeasurements.freshRate("isolated_prefill") != nil
            && performanceMeasurements.freshRate("decode") != nil
        if complete { mimoCalibration.bootstrapCompleted = true }
        let delay = Task.isCancelled || mimoCalibration.interrupted
            ? MimoCalibrationPolicy.interruptionBackoff
            : complete ? MimoCalibrationPolicy.refreshAge : MimoCalibrationPolicy.failureBackoff
        mimoCalibration.nextAttempt = ContinuousClock.now.advanced(by: delay)
        mimoCalibration.task = nil
        performanceUpdates?.notify()
    }

    func cancelMimoCalibration() -> Task<Void, Never>? {
        mimoCalibration.closed = true
        let task = mimoCalibration.task
        task?.cancel()
        return task
    }

    func stopMimoCalibration() async {
        await cancelMimoCalibration()?.value
    }
}
