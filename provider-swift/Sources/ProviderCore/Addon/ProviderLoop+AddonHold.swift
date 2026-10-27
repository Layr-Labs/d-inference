import Foundation

/// Reversible add-on hold. While a local add-on (the sandbox VM host) uses the
/// Mac, the provider stays registered but closes admission, announces
/// `status: draining` with busy fields at once, lets accepted work finish
/// within a bound, then unloads every model and frees KV pools and caches.
/// Release reopens admission on the same connection. The hold never sends the
/// `provider_drain` barrier, which fences a connection until it closes, and
/// never stops the App Attest worker.
extension ProviderLoop {
    /// Accepted inference gets the background update's drain budget; work
    /// that outlives it is cancelled so its model does not stay resident
    /// beside the add-on's VMs.
    static let addonHoldDrainTimeoutDefault: Duration = .seconds(120)
    /// Load transitions get this long to settle before models unload anyway.
    static let addonHoldSettleTimeoutDefault: Duration = .seconds(60)

    var addonHoldActive: Bool { !addonHolds.isEmpty }

    // MARK: - Service

    /// Restores a persisted hold before anything can load a model, then
    /// accepts add-on connections. Tests and embedded hosts without host
    /// services get no socket and no persistence unless they inject paths.
    internal func startAddonHoldService() {
        guard addonHoldPaths == nil,
              let paths = addonHoldPathsOverride ?? (serveUsesHostServices ? AddonHoldPaths.production() : nil)
        else { return }
        addonHoldPaths = paths
        restoreAddonHolds()
        let policy = AddonPeerPolicy.current()
        let authenticate: AddonIPCServer.Authenticate = addonPeerAuthenticatorOverride ?? { policy.authenticate($0) }
        let log = logger
        let server = AddonIPCServer(
            socketURL: paths.socket, authenticate: authenticate,
            handle: { [weak self] request, peer in
                await self?.handleAddonIPC(request, peer: peer) ?? .failure(.unavailable)
            },
            log: { log.warning($0) })
        do {
            try server.start()
            addonIPCServer = server
            logger.info("Add-on IPC listening at \(paths.socket.path)")
        } catch {
            logger.warning("Add-on IPC unavailable; add-ons cannot hold this provider: \(error)")
        }
    }

    /// The hold record stays on disk: a replacement process comes back held.
    internal func stopAddonHoldService() {
        addonIPCServer?.stop()
        addonIPCServer = nil
        addonHoldMonitorTask?.cancel()
        addonHoldMonitorTask = nil
        addonHoldTask?.cancel()
        addonHoldTask = nil
    }

    // MARK: - Requests

    func handleAddonIPC(_ request: AddonIPC.Request, peer: AddonPeer) -> AddonIPC.Response {
        switch request {
        case .hello:
            return .hello(providerVersion: ProviderCore.version)
        case .hold(let addon, let vmBytes, let leaseSeconds):
            // The claimed add-on must be the verified signer.
            guard addon == peer.identifier else { return .failure(.unauthorized) }
            guard let hold = holdForAddon(addon, vmBytes: vmBytes, leaseSeconds: leaseSeconds) else {
                return .failure(.unavailable)
            }
            return .hold(holdID: hold.holdID, state: Self.ipcState(hold.state), sinceMs: hold.sinceMs,
                         leaseExpiresAtMs: hold.leaseExpiresAtMs)
        case .status(let holdID):
            switch ownedHold(holdID, peer: peer) {
            case .active(let hold):
                return .status(state: Self.ipcState(hold.state), sinceMs: hold.sinceMs,
                               leaseExpiresAtMs: hold.leaseExpiresAtMs)
            case .ended(let ended):
                return .status(state: Self.ipcState(ended.outcome), sinceMs: ended.hold.sinceMs,
                               leaseExpiresAtMs: ended.hold.leaseExpiresAtMs)
            case .missing:
                return .failure(.notFound)
            }
        case .renew(let holdID, let leaseSeconds):
            switch ownedHold(holdID, peer: peer) {
            case .active(let hold):
                let renewed = renewAddonHold(hold, leaseSeconds: leaseSeconds)
                return .renewed(state: Self.ipcState(renewed.state), leaseExpiresAtMs: renewed.leaseExpiresAtMs)
            case .ended(let ended):
                // An ended hold is not revived; the add-on must hold again.
                return .renewed(state: Self.ipcState(ended.outcome), leaseExpiresAtMs: ended.hold.leaseExpiresAtMs)
            case .missing:
                return .failure(.notFound)
            }
        case .release(let holdID):
            switch ownedHold(holdID, peer: peer) {
            case .active(let hold):
                endAddonHold(holdID: hold.holdID, as: .released)
                return .released
            case .ended:
                return .released
            case .missing:
                return .failure(.notFound)
            }
        }
    }

    private enum OwnedHold {
        case active(AddonHold)
        case ended(AddonHoldBook.Ended)
        case missing
    }

    /// A peer sees only holds of its own identifier; others are missing.
    private func ownedHold(_ holdID: String, peer: AddonPeer) -> OwnedHold {
        if let hold = addonHolds.active(holdID: holdID), hold.addon == peer.identifier { return .active(hold) }
        if let ended = addonHolds.ended(holdID: holdID), ended.hold.addon == peer.identifier { return .ended(ended) }
        return .missing
    }

    internal func acceptPendingAddonControl(from mailbox: LifecycleMailbox) -> AddonHoldControlStatus? {
        guard let request = mailbox.claimAddonRequest(), request.isValid(for: mailbox.identity) else { return nil }
        let status = handleAddonControl(request)
        try? mailbox.writeAddonStatus(status)
        return status
    }

    /// `darkbloom addon`. Release refuses while the machine lock is held
    /// unless forced: VMs may still be using the memory models would take.
    internal func handleAddonControl(_ request: AddonHoldControlRequest) -> AddonHoldControlStatus {
        var failure: AddonHoldControlStatus.Failure?
        let lockHeld = machineLockObservation() == .held
        switch request.action {
        case .status:
            break
        case .hold:
            let lease = request.leaseSeconds ?? AddonHold.leaseSecondsRange.upperBound
            if holdForAddon(AddonHoldControlRequest.operatorAddon, vmBytes: 0, leaseSeconds: lease) == nil {
                failure = .unavailable
            }
        case .release:
            if lockHeld && !request.force {
                failure = .machineLockHeld
            } else {
                for hold in addonHolds.sorted { endAddonHold(holdID: hold.holdID, as: .released) }
            }
        }
        return AddonHoldControlStatus(requestID: request.id, failure: failure,
                                      holds: addonHolds.sorted.map(\.view), machineLockHeld: lockHeld)
    }

    // MARK: - Transitions

    /// Accepts a hold, or renews this add-on's active one: one hold per
    /// add-on. Nil when a stop or a model switch owns admission.
    func holdForAddon(_ addon: String, vmBytes: UInt64, leaseSeconds: Int) -> AddonHold? {
        if let hold = addonHolds.active[addon] {
            return renewAddonHold(hold, leaseSeconds: leaseSeconds, vmBytes: vmBytes)
        }
        guard !isShuttingDown, servingDrain.owner != .lifecycle, servingDrain.owner != .modelSwitch,
              modelSwitchTask == nil else { return nil }
        let first = addonHolds.isEmpty
        let hold = AddonHold(addon: addon, vmBytes: vmBytes, state: first ? .draining : addonHolds.state,
                             sinceMs: addonHoldNowMs(), leaseSeconds: leaseSeconds)
        addonHolds.insert(hold)
        logger.info("Add-on hold accepted from \(addon): lease \(leaseSeconds)s, closing admission")
        AddonHoldTelemetry.emit(.begin, hold: hold, inFlight: lifecycleRemaining)
        if first { enterAddonHold() } else { publishAddonBusy() }
        persistAddonHolds()
        writeDaemonState()
        startAddonHoldMonitor()
        return hold
    }

    @discardableResult
    private func renewAddonHold(_ hold: AddonHold, leaseSeconds: Int, vmBytes: UInt64? = nil) -> AddonHold {
        var renewed = hold
        renewed.renew(leaseSeconds: leaseSeconds, nowMs: addonHoldNowMs())
        if let vmBytes { renewed.vmBytes = vmBytes }
        addonHolds.recordRenewal(renewed)
        persistAddonHolds()
        AddonHoldTelemetry.emit(.renewed, hold: renewed)
        writeDaemonState()
        return renewed
    }

    /// Ends one hold; the last one reopens admission on the same connection.
    @discardableResult
    func endAddonHold(holdID: String, as outcome: AddonHoldBook.Outcome) -> AddonHold? {
        guard let hold = addonHolds.end(holdID: holdID, as: outcome) else { return nil }
        persistAddonHolds()
        logger.info("Add-on hold from \(hold.addon) \(outcome.rawValue)")
        AddonHoldTelemetry.emit(outcome == .released ? .released : .expired, hold: hold)
        if addonHolds.isEmpty { leaveAddonHold() } else { publishAddonBusy() }
        writeDaemonState()
        return hold
    }

    private func enterAddonHold() {
        addonHoldGeneration &+= 1
        let generation = addonHoldGeneration
        beginServingDrain(owner: .addonHold)
        publishAddonBusy()
        // Coordinator preloads would load models the hold is about to unload.
        for task in preloadTasks.values { task.cancel() }
        // Announce now: routing stops on the status, not on 503 bounces.
        if let client = coordinatorClient { Task { await client.sendEventHeartbeat() } }
        addonHoldTask = Task { [weak self] in await self?.settleAddonHold(generation: generation) }
    }

    private func leaveAddonHold() {
        addonHoldGeneration &+= 1
        addonHoldTask?.cancel()
        addonHoldTask = nil
        state.busy = nil
        // A stop that took over keeps admission closed.
        guard servingDrain.owner == .addonHold else { return }
        resumeAfterAddonHold()
        localResponseTracker.setAccepting(!servingDrain.refusing && !isShuttingDown)
        state.refusingNewWork = servingDrain.refusing || isReconnectingAfterRetirement
            || isShuttingDown || autopilotCommand != nil
        if !servingDrain.refusing { lifecycleStatus = .init() }
        Task { await self.announceAddonHoldRelease() }
    }

    /// Re-probe headroom (the VMs just returned their memory), announce the
    /// routable status, then replay desired_models deferred during the hold.
    private func announceAddonHoldRelease() async {
        await refreshActivationReserve()
        await updateAggregateCapacity()
        await coordinatorClient?.sendEventHeartbeat()
        guard !servingDrain.refusing, !addonHoldActive else { return }
        if let entries = deferredDesiredModels, let send = outboundSend {
            deferredDesiredModels = nil
            logger.info("Replaying desired_models deferred during the add-on hold (\(entries.count) entr(ies))")
            await reconcileDesiredModels(entries, send: send)
        }
    }

    /// The drain this hold owns: accepted work, then every model.
    private func settleAddonHold(generation: UInt64) async {
        let drainDeadline = ContinuousClock.now.advanced(by: addonHoldDrainTimeout)
        while ownsAddonHold(generation), lifecycleRemaining > 0, ContinuousClock.now < drainDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ownsAddonHold(generation) else { return }
        if lifecycleRemaining > 0 {
            let remaining = lifecycleRemaining
            logger.warning("Add-on hold: \(remaining) accepted request(s) still running after \(addonHoldDrainTimeout.components.seconds)s; cancelling them so the models can unload")
            AddonHoldTelemetry.emit(.drainTimedOut, hold: addonHolds.oldest, inFlight: remaining)
            await cancelRequestsOutlivingAddonHoldDrain(generation: generation)
        }
        let retained = await unloadAllModelsForAddonHold(generation: generation)
        guard ownsAddonHold(generation) else { return }
        await releaseReclaimableMemoryForLoad()
        await refreshActivationReserve()
        await updateAggregateCapacity()
        guard ownsAddonHold(generation) else { return }
        addonHolds.markHeld()
        publishAddonBusy()
        persistAddonHolds()
        writeDaemonState()
        if retained.isEmpty {
            logger.info("Add-on hold: every model unloaded; the Mac is held")
        } else {
            logger.error("Add-on hold: \(retained.joined(separator: ", ")) could not be retired and stays resident; the Mac is held")
        }
        AddonHoldTelemetry.emit(.held, hold: addonHolds.oldest)
        addonHoldTask = nil
        await coordinatorClient?.sendEventHeartbeat()
    }

    private func ownsAddonHold(_ generation: UInt64) -> Bool {
        generation == addonHoldGeneration && servingDrain.owner == .addonHold && !isShuttingDown && !Task.isCancelled
    }

    /// Cancels the coordinator requests still running at the drain bound,
    /// and only those, while this hold lasts. Each cancellation suspends, and
    /// a release meanwhile reopens admission: the pass then stops, and work
    /// accepted after the release keeps its task and tracking.
    /// (`cancelAllInflight` clears every tracking map, as a lost connection needs.)
    private func cancelRequestsOutlivingAddonHoldDrain(generation: UInt64) async {
        let stragglers = Set(inflightTasks.keys)
            .union(requestToModel.keys.filter { !$0.hasPrefix(Self.engineV2RecoveryPinPrefix) })
        await addonHoldBeforeCancellingStragglersForTesting?()
        for requestID in stragglers.sorted() {
            guard ownsAddonHold(generation) else { return }
            // One that finished meanwhile needs nothing.
            guard inflightTasks[requestID] != nil || requestToModel[requestID] != nil else { continue }
            await handleCancellation(requestId: requestID, receivedFromCoordinator: false)
        }
    }

    /// Unloads every resident model once load transitions settle. A load
    /// still running at the settle bound cannot publish its slot
    /// (`addonHoldLoadRefusal`), but it owns memory until it unwinds, so the
    /// hold waits for the load gate before its last sweep. Returns the models
    /// a faulted retirement keeps resident.
    private func unloadAllModelsForAddonHold(generation: UInt64) async -> [String] {
        let settleDeadline = ContinuousClock.now.advanced(by: addonHoldSettleTimeout)
        while ContinuousClock.now < settleDeadline {
            guard ownsAddonHold(generation) else { return [] }
            if modelSwitchMutationsSettled {
                if modelSlots.isEmpty { return [] }
                await unloadResidentModels(generation: generation)
                await retryPendingNativeMiMoRetirements()
                if modelSlots.isEmpty { return [] }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if isLoadingAny {
            logger.warning("Add-on hold: a model load is still unwinding; the Mac is held once it ends")
        }
        while isLoadingAny {
            guard ownsAddonHold(generation) else { return [] }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await unloadResidentModels(generation: generation)
        return modelSlots.keys.sorted()
    }

    private func unloadResidentModels(generation: UInt64) async {
        for modelID in modelSlots.keys.sorted() where !modelsUnloading.contains(modelID) {
            guard ownsAddonHold(generation) else { return }
            await unloadModel(modelID)
        }
    }

    private func publishAddonBusy() {
        state.busy = addonHolds.oldest.map { ProviderBusy(reason: .addon, sinceMs: $0.sinceMs, addon: $0.addon) }
    }

    // MARK: - Model load fence

    /// While any hold is active no model may start loading or publish a slot:
    /// the add-on's VMs need the memory. A load already running when the hold
    /// began ends at its next check instead of installing. The refusal is
    /// transient (`loadErrorStatusCode` maps it to 503), so callers retry
    /// elsewhere or after the release.
    func addonHoldLoadRefusal(for modelID: String) -> InferenceError? {
        guard addonHoldActive else { return nil }
        return .modelLoadFailed("An add-on holds this Mac; '\(modelID)' cannot load until it releases")
    }

    // MARK: - Leases

    private func startAddonHoldMonitor() {
        guard addonHoldMonitorTask == nil else { return }
        addonHoldMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, await self.enforceAddonHoldLeases() else { return }
            }
        }
    }

    /// One lease check; returns whether holds remain to watch. An expired
    /// lease ends its hold only while no add-on holds the machine lock, so a
    /// crashed add-on with VMs still running keeps the Mac held.
    @discardableResult
    internal func enforceAddonHoldLeases() -> Bool {
        let now = addonHoldNowMs()
        let expired = addonHolds.sorted.filter { $0.leaseExpired(nowMs: now) }
        if !expired.isEmpty {
            if machineLockObservation() == .free {
                for hold in expired { endAddonHold(holdID: hold.holdID, as: .expired) }
            } else {
                for hold in expired where addonHolds.keepForMachineLock(holdID: hold.holdID) {
                    logger.warning("Add-on hold lease from \(hold.addon) expired while the machine lock is held; keeping the hold until the lock is released")
                    AddonHoldTelemetry.emit(.keptByMachineLock, hold: hold)
                }
            }
        }
        guard addonHoldActive else {
            addonHoldMonitorTask = nil
            return false
        }
        return true
    }

    private func machineLockObservation() -> AddonMachineLock.Observation {
        addonHoldPaths.map { AddonMachineLock.observe($0.machineLock) } ?? .free
    }

    // MARK: - Persistence

    private func persistAddonHolds() {
        guard let paths = addonHoldPaths else { return }
        do {
            try AddonHoldStore(url: paths.holdState).write(addonHolds.sorted)
        } catch {
            logger.warning("Add-on hold: cannot persist the hold record: \(error)")
        }
    }

    /// A restarted or updated provider comes back held while a lease is
    /// valid or the machine lock is held. Nothing is loaded or running this
    /// early in startup, so a restored hold is immediately `held`.
    private func restoreAddonHolds() {
        guard let paths = addonHoldPaths else { return }
        let records: [AddonHold]
        switch AddonHoldStore(url: paths.holdState).read() {
        case .absent:
            return
        case .invalid:
            logger.warning("Add-on hold: ignoring an unreadable hold record at \(paths.holdState.path)")
            return
        case .holds(let holds):
            records = holds
        }
        let now = addonHoldNowMs()
        let lockHeld = machineLockObservation() == .held
        var restored: [AddonHold] = []
        for var hold in records {
            guard lockHeld || !hold.leaseExpired(nowMs: now) else {
                logger.info("Add-on hold from \(hold.addon) expired while the provider was stopped")
                AddonHoldTelemetry.emit(.expired, hold: hold)
                continue
            }
            hold.state = .held
            restored.append(hold)
        }
        addonHolds = AddonHoldBook(restoring: restored)
        persistAddonHolds()
        guard !restored.isEmpty else { return }
        addonHoldGeneration &+= 1
        beginServingDrain(owner: .addonHold)
        publishAddonBusy()
        for hold in addonHolds.sorted {
            logger.info("Add-on hold from \(hold.addon) restored; models stay unloaded")
            AddonHoldTelemetry.emit(.restored, hold: hold)
        }
        startAddonHoldMonitor()
    }

    /// Called for every fresh registration while held. The register already
    /// carried the busy fields; the event heartbeat repeats the draining status.
    internal func reassertAddonHoldAfterReconnect() {
        guard addonHoldActive, servingDrain.owner == .addonHold else { return }
        logger.info("Add-on hold re-asserted on the new coordinator connection")
        AddonHoldTelemetry.emit(.reasserted, hold: addonHolds.oldest)
    }

    var addonHoldSnapshot: AddonHoldSnapshot? {
        addonHoldPaths == nil && !addonHoldActive ? nil : AddonHoldSnapshot(holds: addonHolds.sorted.map(\.view))
    }

    private static func ipcState(_ state: AddonHold.State) -> AddonIPC.HoldState {
        state == .held ? .held : .draining
    }

    private static func ipcState(_ outcome: AddonHoldBook.Outcome) -> AddonIPC.HoldState {
        outcome == .released ? .released : .expired
    }
}
