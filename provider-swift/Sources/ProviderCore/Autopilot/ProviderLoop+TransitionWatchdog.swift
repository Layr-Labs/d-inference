import Foundation

extension ProviderLoop {
    static let transitionStalledError = "transition_stalled"

    /// One supervision pass on the capacity tick while Autopilot consent is
    /// saved. Every stall is counted in `transition_stalls` and logged. Only
    /// work that cannot fail anyone else is interrupted: an accepted operation
    /// excludes every other load and admission, so it alone is cancelled.
    /// Interrupting a preload or the startup driver could cancel a load that
    /// other requests wait on, and wastes a slow but healthy load, so those are
    /// answered or stopped at their next step instead. No load, admission,
    /// drain or reconnect flag is ever cleared here: an owner that may still
    /// allocate memory keeps its fence.
    func superviseTransitions(now: ContinuousClock.Instant = .now) {
        guard autopilotConsented, !isShuttingDown else {
            transitionWatchdog.forgetOccurrences()
            return
        }
        for stall in transitionWatchdog.observe(activeTransitions(), now: now) {
            let action = resolveStalledTransition(stall.occurrence)
            logger.warning("transition_stalled transition=\(stall.occurrence.transition.rawValue) "
                + "subject=\(stall.occurrence.subject) age_s=\(stall.age.components.seconds) action=\(action)")
        }
    }

    private func activeTransitions() -> Set<TransitionWatchdog.Occurrence> {
        var active = Set<TransitionWatchdog.Occurrence>()
        if let command = autopilotCommand {
            active.insert(.init(.autopilotOperation, subject: command.commandId))
        }
        if startupPreloadTask != nil {
            active.insert(.init(.startupPreload, subject: startupPreloadPendingModels.first ?? ""))
        }
        for (model, taskId) in preloadTaskIds where preloadTasks[model] != nil {
            active.insert(.init(.preload, subject: model, generation: taskId.uuidString))
        }
        for model in modelsLoading { active.insert(.init(.modelLoading, subject: model)) }
        if isLoadingAny && modelsLoading.isEmpty { active.insert(.init(.modelLoading)) }
        for model in Set(prefetchPublicationCounts.keys).union(pendingAdvertise) {
            active.insert(.init(.modelAdvertisement, subject: model))
        }
        if modelSwitchTask != nil { active.insert(.init(.modelSwitch)) }
        if isReslicing { active.insert(.init(.reslice, generation: String(resliceGateGeneration))) }
        if isReconnectingAfterRetirement {
            active.insert(.init(.reconnectAfterRetirement, generation: String(plannedReconnectTaskGeneration)))
        }
        return active
    }

    /// Returns the action taken, for the log.
    private func resolveStalledTransition(_ occurrence: TransitionWatchdog.Occurrence) -> String {
        switch occurrence.transition {
        case .autopilotOperation:
            guard autopilotCommand?.commandId == occurrence.subject, let task = autopilotTask else { return "reported" }
            autopilotStalledCommandId = occurrence.subject
            task.cancel()
            return "cancelled"
        case .startupPreload:
            guard startupPreloadTask != nil else { return "reported" }
            startupPreloadStopRequested = true
            return "stopping"
        case .preload:
            guard let taskId = preloadTaskIds[occurrence.subject], taskId.uuidString == occurrence.generation
            else { return "reported" }
            // Answer the coordinator now and untrack the task so a new request
            // starts afresh rather than waiting on it. The task finishes on its
            // own; its later result is not sent again.
            finishPreloadTask(modelId: occurrence.subject, taskId: taskId, status: .failed,
                error: Self.transitionStalledError)
            return "answered"
        case .modelLoading, .modelAdvertisement, .modelSwitch, .reslice, .reconnectAfterRetirement:
            return "reported"
        }
    }
}
