import Foundation

// The pair's coordinated update, on the coordinator-paired part (`ClusterPairUpdateCycle`).
//
// A member serves coordinator work only through its pair slot, so only the leader's part (rank 0) has accepted
// requests to finish. On its supervisor's request it closes admission exactly as the single-Mac updater does
// (`beginUpdateDraining`: refused requests are rerouted, the heartbeat says draining) and waits, bounded, for the
// accepted ones. It never cancels one and sends no drain barrier: a drain the pair gives up is undone on the same
// coordinator connection, and the stop that follows a completed drain sends the barrier as every stop does
// (`drainAndShutdown`).

extension ProviderLoop {
    internal func acceptPendingClusterUpdateDrain(from mailbox: LifecycleMailbox) async {
        guard isClusterMember, loopConfig.clusterMemberAnswersUpdateDrain,
              let request = mailbox.claimClusterUpdateDrainRequest(), request.isValid(for: mailbox.identity) else { return }
        func report(_ outcome: ClusterUpdateDrainStatus.Outcome) {
            try? mailbox.writeClusterUpdateDrainStatus(.init(requestID: request.id, outcome: outcome, remaining: lifecycleRemaining))
        }
        switch request.action {
        case .drain:
            guard clusterUpdateDrainID == nil else { return report(.refused) }
            clusterUpdateDrainID = request.id
            clusterUpdateDrainTask = Task { await self.performClusterUpdateDrain(request, mailbox: mailbox) }
        case .release:
            let held = clusterUpdateDrainID != nil
            clusterUpdateDrainID = nil
            clusterUpdateDrainTask?.cancel()
            clusterUpdateDrainTask = nil
            if held, servingDrain.owner == .update, !isShuttingDown {
                logger.info("Cluster update given up: taking requests again")
                await resumeAfterClusterUpdateDrain()
            }
            report(.released)
        }
    }

    private func performClusterUpdateDrain(_ request: ClusterUpdateDrainRequest, mailbox: LifecycleMailbox) async {
        func report(_ outcome: ClusterUpdateDrainStatus.Outcome) {
            try? mailbox.writeClusterUpdateDrainStatus(.init(requestID: request.id, outcome: outcome, remaining: lifecycleRemaining))
        }
        // Released, stopped or taken over by a stop meanwhile: the drain is no longer this request's.
        func owned() -> Bool { clusterUpdateDrainID == request.id && servingDrain.owner == .update && !isShuttingDown }
        defer { if clusterUpdateDrainID == nil || clusterUpdateDrainID == request.id { clusterUpdateDrainTask = nil } }
        guard let slot = clusterPairSlot, clusterPairSlotServes(slot.modelID) else {
            clusterUpdateDrainID = nil
            return report(.notServing)
        }
        guard updatePhase == .idle, !servingDrain.refusing, !isShuttingDown, !memberControlRequiresStop else {
            clusterUpdateDrainID = nil
            return report(.refused)
        }
        logger.info("Cluster update: the pair takes no new requests; finishing the accepted ones (at most \(request.timeoutSeconds) s)")
        beginUpdateDraining()
        report(.draining)
        let drained = await waitForInflightDrain(timeout: .seconds(request.timeoutSeconds), reason: "the cluster's update")
        guard owned() else { return }
        guard drained else {
            logger.warning("Cluster update deferred: \(lifecycleRemaining) accepted request(s) still running after \(request.timeoutSeconds) s; none cancelled; taking requests again")
            clusterUpdateDrainID = nil
            await resumeAfterClusterUpdateDrain()
            return report(.timedOut)
        }
        logger.info("Cluster update: no accepted request left; new requests stay refused until this part stops")
        report(.drained)
        try? await Task.sleep(nanoseconds: UInt64(ClusterPairUpdate.drainedHoldSeconds * 1_000_000_000))
        guard owned(), !Task.isCancelled else { return }
        logger.warning("Cluster update: no stop arrived within \(Int(ClusterPairUpdate.drainedHoldSeconds)) s of the drain; taking requests again")
        clusterUpdateDrainID = nil
        await resumeAfterClusterUpdateDrain()
    }

    /// The single-Mac resume (`resumeServingAfterUpdate`) for a member: its admission follows its pair slot.
    private func resumeAfterClusterUpdateDrain() async {
        updatePhase = .idle
        resumeAfterUpdateDrain()
        localResponseTracker.setAccepting(!servingDrain.refusing && !isShuttingDown)
        if !servingDrain.refusing { lifecycleStatus = .init() }
        refreshClusterMemberAdmission()
        if let client = coordinatorClient { await client.sendEventHeartbeat() }
    }
}
