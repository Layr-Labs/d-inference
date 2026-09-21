import Foundation

extension ProviderLoop {
    internal func beginServingDrain(owner: ProviderDrain.Owner) {
        servingDrain.begin(owner)
        localResponseTracker.setAccepting(false)
        state.refusingNewWork = true
    }

    internal var lifecycleRemaining: Int {
        let coordinator = Set(requestToModel.keys.filter { !$0.hasPrefix(Self.engineV2RecoveryPinPrefix) })
            .union(inflightTasks.keys).union(acceptedLifecycleRequests).count
        return coordinator + max(localReservations.totalInFlight, localResponseTracker.activeCount)
    }

    /// Unstructured ownership is intentional: interrupting the CLI, a schedule
    /// task, or the AppKit callback must not cancel accepted inference.
    public func drainForLifecycle(request: ProviderDrainRequest) async -> ProviderDrainStatus {
        while let task = lifecycleDrainTask {
            if lifecycleDrainRequestID == request.id { return await task.value }
            let previousID = lifecycleDrainRequestID
            task.cancel()
            _ = await task.value
            if lifecycleDrainRequestID == previousID { lifecycleDrainTask = nil }
        }
        let task = Task { await self.performLifecycleDrain(request: request) }
        lifecycleDrainRequestID = request.id
        lifecycleDrainTask = task
        let result = await task.value
        if lifecycleDrainRequestID == request.id { lifecycleDrainTask = nil }
        return result
    }

    private func performLifecycleDrain(request: ProviderDrainRequest) async -> ProviderDrainStatus {
        beginServingDrain(owner: .lifecycle)
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timeoutSeconds))
        lifecycleStatus = ProviderDrainStatus(requestID: request.id, outcome: .draining,
            remaining: lifecycleRemaining, deadline: Date().timeIntervalSince1970 + Double(request.timeoutSeconds))
        publishLifecycleStatus()

        // A signal may overlap staging or an update drain. Cancel its driver;
        // the controller's cancellation fences prevent commit/restart and its
        // resume hook cannot reopen lifecycle-owned admission.
        let update = autoUpdateTask
        autoUpdateTask = nil
        update?.cancel()
        if let client = coordinatorClient {
            await client.sendEventHeartbeat()
            if !request.force && request.timeoutSeconds > 0 {
                _ = await client.acknowledgeDrain(timeout: .seconds(min(10, request.timeoutSeconds)))
            }
        }

        if request.force {
            isShuttingDown = true
            await cancelAllInflight()
            stopLocalEndpoint()
        }
        let finishDeadline = request.force ? ContinuousClock.now.advanced(by: .seconds(5)) : deadline
        while lifecycleRemaining > 0 && !Task.isCancelled && ContinuousClock.now < finishDeadline {
            lifecycleStatus.remaining = lifecycleRemaining
            publishLifecycleStatus()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        // Do not claim success just because the engine finished: the FIFO
        // coordinator acknowledgement follows all terminal/usage messages.
        var acknowledged = false
        if !Task.isCancelled, lifecycleRemaining == 0, let client = coordinatorClient, ContinuousClock.now < finishDeadline {
            acknowledged = await client.acknowledgeDrain(timeout: ContinuousClock.now.duration(to: finishDeadline))
        }
        lifecycleStatus.remaining = lifecycleRemaining
        lifecycleStatus.coordinatorAcknowledged = acknowledged
        if request.force {
            lifecycleStatus.outcome = .forced
            servingDrain.drained()
        } else if lifecycleRemaining == 0 && (acknowledged || coordinatorClient == nil) {
            lifecycleStatus.outcome = .drained
            servingDrain.drained()
        } else {
            // Recoverable and still draining. Repeating stop/restart grants a
            // new deadline; only an explicit --force permits truncation.
            lifecycleStatus.outcome = .timedOut
        }
        publishLifecycleStatus()
        return lifecycleStatus
    }

    internal func publishLifecycleStatus() {
        if let identity = ProcessIdentity.current() {
            try? LifecycleMailbox(identity: identity, directory: (daemonStateFileOverride ?? DaemonStateFile.path()).deletingLastPathComponent().appendingPathComponent("lifecycle")).writeStatus(lifecycleStatus)
        }
        writeDaemonState()
        if lastLifecycleTelemetry != lifecycleStatus {
            lastLifecycleTelemetry = lifecycleStatus
            ProviderDrainTelemetry.emit(lifecycleStatus)
        }
    }

    internal func startLifecycleMonitor() {
        guard lifecycleMonitorTask == nil, let identity = ProcessIdentity.current() else { return }
        let mailbox = LifecycleMailbox(identity: identity, directory: (daemonStateFileOverride ?? DaemonStateFile.path()).deletingLastPathComponent().appendingPathComponent("lifecycle"))
        lifecycleMonitorTask = Task { [weak self] in
            var handled: String?
            while !Task.isCancelled {
                if let request = mailbox.readRequest(), request.id != handled,
                   request.isValid(for: identity) {
                    handled = request.id
                    Task { await self?.handleLifecycleCommand(request) }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func handleLifecycleCommand(_ request: ProviderDrainRequest) async {
        lifecycleCommandReceived = true
        _ = await drainForLifecycle(request: request)
    }

    public func lifecycleIsCommandDriven() -> Bool { lifecycleCommandReceived }

    /// OS termination and schedule cancellation use the same admission/drain
    /// path. Neither cancels the event reader or closes the socket first.
    public func drainAndShutdown(timeoutSeconds: Int = 600) async -> Bool {
        if servingDrain.phase == .drained {
            await coordinatorClient?.shutdown()
            return true
        }
        guard let identity = ProcessIdentity.current() else { return false }
        let result: ProviderDrainStatus
        if let task = lifecycleDrainTask { result = await task.value }
        else { result = await drainForLifecycle(request: ProviderDrainRequest(target: identity, timeoutSeconds: timeoutSeconds)) }
        guard result.outcome == .drained || result.outcome == .forced else { return false }
        await coordinatorClient?.shutdown()
        return true
    }
}
