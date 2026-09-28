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
        case .disconnected, .runtimeOutdated:
            // No grant or key is retained across a control connection boundary.
            memberConnectionID = nil
            memberControlRequiresStop = loopConfig.clusterMemberStopsOnDisconnect && memberHadAcceptedConnection
        case .inferenceRequest(let id, _, _, _, _, _, _, _, _, _, _):
            rejectClusterMemberInference(id, send: send)
            return true
        case .loadModel(let id):
            rejectClusterMemberLoad(id, send: send)
            return true
        case .prefetchModel(let id, _):
            rejectClusterMemberPrefetch(id, send: send)
            return true
        case .desiredModels:
            // Desired solo residency has no meaning in this role. No retry or
            // delayed task is retained, including an empty revoke.
            return true
        case .trustStatus(_, let status, _):
            if status == "untrusted" || status == "offline" {
                memberConnectionID = nil
                memberControlRequiresStop = loopConfig.clusterMemberStopsOnDisconnect && memberHadAcceptedConnection
            }
        default: break
        }
        return false
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
                memberRegistrationTimer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                    guard !Task.isCancelled else { return }
                    await self?.finishMemberRegistrationWait(ClusterMemberControlError.negotiationFailed, expected: waitID)
                }
            }
        } onCancel: {
            Task { await self.finishMemberRegistrationWait(CancellationError(), expected: waitID) }
        }
    }

    internal func finishMemberRegistrationWait(_ error: Error?, expected waitID: UUID? = nil) {
        if let waitID, memberRegistrationWaitID != waitID { return }
        memberRegistrationTimer?.cancel(); memberRegistrationTimer = nil
        guard let waiter = memberRegistrationWaiter else { return }
        memberRegistrationWaiter = nil
        memberRegistrationWaitID = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}
