import Foundation

extension StandaloneServer {
    public func drainAndStop(timeoutSeconds: Int = 600) async -> Bool {
        let status: ProviderDrainStatus
        if let task = lifecycleDrainTask { status = await task.value }
        else {
            guard let identity = ProcessIdentity.current() else { return false }
            status = await drainForLifecycle(.init(target: identity, timeoutSeconds: timeoutSeconds))
        }
        guard status.outcome == .drained || status.outcome == .forced else { return false }
        await stop()
        return true
    }

    func drainForLifecycle(_ request: ProviderDrainRequest) async -> ProviderDrainStatus {
        while let task = lifecycleDrainTask {
            if lifecycleCommandID == request.id { return await task.value }
            let oldID = lifecycleCommandID
            task.cancel()
            _ = await task.value
            if lifecycleCommandID == oldID { lifecycleDrainTask = nil }
        }
        lifecycleCommandID = request.id
        let task = Task { await self.performLifecycleDrain(request) }
        lifecycleDrainTask = task
        let status = await task.value
        if lifecycleCommandID == request.id { lifecycleDrainTask = nil }
        return status
    }

    private func performLifecycleDrain(_ request: ProviderDrainRequest) async -> ProviderDrainStatus {
        lifecycleDraining = true
        responseTracker.setAccepting(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
        lifecycleStatus = .init(requestID: request.id, outcome: .draining,
                                deadline: Date().timeIntervalSince1970 + Double(request.timeoutSeconds))
        while !request.force && !Task.isCancelled {
            lifecycleStatus.remaining = max(responseTracker.activeCount, slotReservations.values.reduce(0, +))
            if lifecycleStatus.remaining == 0 || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        lifecycleStatus.remaining = max(responseTracker.activeCount, slotReservations.values.reduce(0, +))
        // Explicit force is completed by the CLI's bounded process termination;
        // a stalled HTTP writer cannot block that permission indefinitely.
        lifecycleStatus.outcome = request.force ? .forced : (lifecycleStatus.remaining == 0 ? .drained : .timedOut)
        return lifecycleStatus
    }
}
