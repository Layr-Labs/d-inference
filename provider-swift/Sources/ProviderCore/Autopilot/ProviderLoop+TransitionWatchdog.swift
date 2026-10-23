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
        let (active, began) = activeTransitions()
        for stall in transitionWatchdog.observe(active, now: now, began: began) {
            let action = resolveStalledTransition(stall.occurrence)
            logger.warning("transition_stalled transition=\(stall.occurrence.transition.rawValue) "
                + "subject=\(stall.occurrence.subject) age_s=\(stall.age.components.seconds) action=\(action)")
        }
    }

    /// The current occurrences, and the start of those that can begin before
    /// supervision does: the capacity monitor starts after the startup
    /// preload gate, so a candidate is aged from when it actually began.
    private func activeTransitions()
        -> (active: Set<TransitionWatchdog.Occurrence>, began: [TransitionWatchdog.Occurrence: ContinuousClock.Instant]) {
        var active = Set<TransitionWatchdog.Occurrence>()
        var began: [TransitionWatchdog.Occurrence: ContinuousClock.Instant] = [:]
        if let command = autopilotCommand {
            active.insert(.init(.autopilotOperation, subject: command.commandId))
        }
        if startupPreloadTask != nil {
            let model = startupPreloadCandidate?.model ?? startupPreloadPendingModels.first ?? ""
            let occurrence = TransitionWatchdog.Occurrence(.startupPreload, subject: model,
                generation: transitionGenerations.generation(of: .startupPreload, subject: model))
            active.insert(occurrence)
            if let candidate = startupPreloadCandidate, candidate.model == model {
                began[occurrence] = candidate.startedAt
            }
        }
        for (model, taskId) in preloadTaskIds where preloadTasks[model] != nil {
            active.insert(.init(.preload, subject: model, generation: taskId.uuidString))
        }
        for model in modelsLoading {
            active.insert(.init(.modelLoading, subject: model,
                generation: transitionGenerations.generation(of: .modelLoading, subject: model)))
        }
        if isLoadingAny && modelsLoading.isEmpty {
            active.insert(.init(.modelLoading, generation: transitionGenerations.generation(of: .modelLoading)))
        }
        for model in Set(prefetchPublicationCounts.keys).union(pendingAdvertise) {
            active.insert(.init(.modelAdvertisement, subject: model,
                generation: transitionGenerations.generation(of: .modelAdvertisement, subject: model)))
        }
        if modelSwitchTask != nil {
            active.insert(.init(.modelSwitch, generation: transitionGenerations.generation(of: .modelSwitch)))
        }
        if isReslicing { active.insert(.init(.reslice, generation: String(resliceGateGeneration))) }
        if isReconnectingAfterRetirement {
            active.insert(.init(.reconnectAfterRetirement, generation: String(plannedReconnectTaskGeneration)))
        }
        return (active, began)
    }

    /// A build entering publication (`prefetchPublicationCounts` or
    /// `pendingAdvertise`) starts a new advertisement occurrence.
    func beginModelAdvertisementOccurrence(_ model: String) {
        guard prefetchPublicationCounts[model] == nil, !pendingAdvertise.contains(model) else { return }
        transitionGenerations.begin(.modelAdvertisement, subject: model)
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
