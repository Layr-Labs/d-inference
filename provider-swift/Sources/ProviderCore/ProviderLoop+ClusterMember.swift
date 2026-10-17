import Foundation

extension ProviderLoop {
    internal var isClusterMember: Bool { loopConfig.executionRole == .clusterMember }

    /// Called before any solo subsystem can start. No model, GPU probe, cache
    /// maintenance, update/relaunch, capacity monitor or device lease is started.
    internal func prepareClusterMemberControl() throws {
        guard loopConfig.localEndpoint == nil, modelSlots.isEmpty,
              modelsLoading.isEmpty, preloadTasks.isEmpty else {
            throw ClusterMemberControlError.incompatibleConfiguration
        }
        state.refusingNewWork = true
        state.backendCapacity = BackendCapacity(slots: [], gpuMemoryActiveGb: 0,
            gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0,
            totalMemoryGb: Double(loopConfig.hardware.memoryGb), freeForLoadGb: 0)
        writeDaemonState()
    }

    /// The actual event dispatcher calls this before its ordinary switch. Direct
    /// work handlers also refuse member mode, guarding internal/test entry points.
    internal func consumeClusterMemberEvent(_ event: CoordinatorEvent, send: SendHandle) -> Bool {
        guard isClusterMember else { return false }
        if memberControlRequiresStop { return true }
        switch event {
        case .connected:
            // CoordinatorClient emits this only after nonce-bound role acceptance.
            memberHadAcceptedConnection = true
            memberConnectionID = UUID()
            finishMemberRegistrationWait(nil)
            writeDaemonState()
        case .disconnected:
            // No grant or key is retained across a control connection boundary.
            memberConnectionID = nil
            latchMemberControlStop(Self.memberStopReasonDisconnected)
            // A registration wait past its deadline learns at once that its
            // final attempt ended (before its deadline this is a no-op).
            if memberRegistrationWaiter != nil, let waitID = memberRegistrationWaitID {
                Task { await self.memberRegistrationWaitDue(waitID) }
            }
        case .runtimeOutdated:
            memberConnectionID = nil
            latchMemberControlStop(Self.memberStopReasonRuntimeOutdated)
        case .inferenceRequest(let id, _, _, _, _, _, _, _, _, _, _, _, _, _):
            // A leader serving its pair slot handles the request like any
            // provider; the handler checks the requested model. Every other
            // member refuses it with the retryable no-model answer.
            if clusterPairSlot != nil { return false }
            rejectClusterMemberInference(id, send: send)
            return true
        case .loadModel(let id):
            rejectClusterMemberLoad(id, send: send)
            return true
        case .prefetchModel(let id, _):
            rejectClusterMemberPrefetch(id, send: send)
            return true
        case .desiredModels, .modelAutopilotControl, .modelAutopilot:
            // Solo residency has no meaning in this role: desired builds,
            // autopilot leases and placement commands are all dropped. No
            // retry, delayed task, lease or command is retained, including
            // an empty revoke, and nothing is acknowledged.
            return true
        case .trustStatus(_, let status, _, _):
            if status == "untrusted" || status == "offline" {
                memberConnectionID = nil
                latchMemberControlStop(Self.memberStopReasonTrust(status))
            }
        default: break
        }
        return false
    }

    static let memberStopReasonDisconnected =
        "the coordinator control connection ended; a cluster member keeps no grant or key across it, so serving stops (restart this member once the coordinator is reachable)"
    static let memberStopReasonRuntimeOutdated =
        "the coordinator reported this member's runtime as outdated; serving stops until it is updated"
    static func memberStopReasonTrust(_ status: String) -> String {
        "the coordinator marked this member \(status == "offline" ? "offline" : "untrusted"); serving stops"
    }

    /// The accepted control connection ended or lost trust: the loop stops
    /// instead of reconnecting under a new nonce (only when configured to,
    /// and only after a connection was accepted). The first reason is kept
    /// and stated, so a member that stops on its own says why (a leader then
    /// fails its request in flight and exits; without the reason that stop
    /// looked like a pair failure).
    internal func latchMemberControlStop(_ reason: String) {
        guard loopConfig.clusterMemberStopsOnDisconnect, memberHadAcceptedConnection, !memberControlRequiresStop else { return }
        memberControlRequiresStop = true
        memberStopReason = reason
        logger.warning("cluster member stops: \(reason)")
    }

    internal func rejectClusterMemberInference(_ id: String, send: SendHandle) {
        send.send(.inferenceError(requestId: id,
            failure: InferenceFailure(code: .modelUnavailable, statusCode: 503)))
    }
    internal func rejectClusterMemberLoad(_ id: String, send: SendHandle) {
        send.send(.loadModelStatus(modelId: id, status: .failed,
            error: "Control-only cluster member refuses solo model loading."))
    }
    internal func rejectClusterMemberPrefetch(_ id: String, send: SendHandle) {
        send.send(.prefetchModelStatus(modelId: id, status: .failed,
            bytesDone: 0, bytesTotal: 0,
            error: "Control-only cluster member refuses autonomous model downloads."))
    }

    /// Startup waits for protocol support, not trust/readiness. The existing
    /// coordinator still owns attestation and the future pair start grant.
    ///
    /// The coordinator client keeps its reconnects inside the wait: a retry
    /// its backoff would place after `deadline` is made at the deadline, and
    /// that final attempt, like any attempt under way at the deadline, runs
    /// to the end of its own terms (its handshake, then its connection's
    /// negotiation window) before the wait gives up.
    /// A wait that ends without any attempt reaching the coordinator throws
    /// `coordinatorUnreachable`, not a role refusal (F11). The role check is
    /// unchanged: only this connection's nonce-bound acceptance connects.
    public func waitForClusterMemberRegistration(until deadline: ContinuousClock.Instant) async throws {
        guard isClusterMember else { throw ClusterMemberControlError.incompatibleConfiguration }
        if memberConnectionID != nil { return }
        guard !isShuttingDown, memberRegistrationWaiter == nil, ContinuousClock.now < deadline else {
            throw ClusterMemberControlError.negotiationFailed
        }
        let waitID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                memberRegistrationWaitID = waitID
                memberRegistrationWaiter = continuation
                memberRegistrationWaitDeadline = deadline
                memberRegistrationTimer = Task { [weak self] in
                    await self?.coordinatorClient?.setMemberRegistrationDeadline(deadline)
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.memberRegistrationWaitDue(waitID)
                }
            }
        } onCancel: {
            Task { await self.finishMemberRegistrationWait(CancellationError(), expected: waitID) }
        }
    }

    /// The wait reached its deadline (or, past it, its final attempt ended):
    /// it ends unless the final attempt is still within its terms.
    internal func memberRegistrationWaitDue(_ waitID: UUID) async {
        guard memberRegistrationWaitID == waitID, memberRegistrationWaiter != nil,
              let deadline = memberRegistrationWaitDeadline, ContinuousClock.now >= deadline else { return }
        let progress = await coordinatorClient?.memberRegistrationProgress() ?? .notAccepted
        guard memberRegistrationWaitID == waitID, memberRegistrationWaiter != nil else { return }
        switch progress {
        case .finalAttempt(let until):
            memberRegistrationTimer?.cancel()
            memberRegistrationTimer = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: until) } catch { return }
                guard !Task.isCancelled else { return }
                await self?.memberRegistrationWaitDue(waitID)
            }
        case .unreachable(let reason):
            logger.warning("cluster member registration: the coordinator was not reached before the wait ended (\(reason))")
            finishMemberRegistrationWait(ClusterMemberControlError.coordinatorUnreachable, expected: waitID)
        case .notAccepted:
            finishMemberRegistrationWait(ClusterMemberControlError.negotiationFailed, expected: waitID)
        }
    }

    internal func finishMemberRegistrationWait(_ error: Error?, expected waitID: UUID? = nil) {
        if let waitID, memberRegistrationWaitID != waitID { return }
        memberRegistrationTimer?.cancel(); memberRegistrationTimer = nil
        guard let waiter = memberRegistrationWaiter else { return }
        memberRegistrationWaiter = nil
        memberRegistrationWaitID = nil
        if let ended = memberRegistrationWaitDeadline, let client = coordinatorClient {
            Task { await client.clearMemberRegistrationDeadline(ended) }
        }
        memberRegistrationWaitDeadline = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}
