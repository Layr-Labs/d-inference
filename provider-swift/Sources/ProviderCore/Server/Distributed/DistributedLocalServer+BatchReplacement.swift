import Foundation
import DarkbloomClusterProcess

extension DistributedLocalServer {
    /// A policy may recommend a wider native mode when real requests wait.
    /// Nothing drains while the read-only planner considers that demand.
    func considerBatchReplacement() {
        guard phase == .serving, teardownTask == nil, replacementTask == nil,
              !waiting.isEmpty, let replacementPlanner,
              generation.capacity < DistributedRequestQueue.maximumLanes else { return }
        let target = generation
        let demandCount = min(DistributedRequestQueue.maximumLanes, waiting.count + target.pins.count)
        guard demandCount > target.capacity else { return }
        let now = ContinuousClock.now
        if let ready = readyBatchReplacement {
            readyBatchReplacement = nil
            if ready.isUsable(generationID: target.id, capacity: target.capacity, now: now) {
                replacementTask = Task {
                    defer { replacementTask = nil }
                    guard generation === target, phase == .serving, teardownTask == nil,
                          ready.isUsable(generationID: target.id, capacity: target.capacity, now: .now) else { return }
                    // A disconnect may win before this task runs. Retain only
                    // until the original expiry; idle traffic never reloads.
                    guard !waiting.isEmpty, waiting.count + target.pins.count > target.capacity else {
                        if ready.isUsable(generationID: target.id, capacity: target.capacity, now: .now) {
                            readyBatchReplacement = ready
                        }
                        return
                    }
                    clusterObservabilityLog(.info, "cluster.batch_replan reuse_ready", [
                        "generation": target.id.uuidString.lowercased(),
                        "requested_lanes": String(ready.intent.requestedCapacity),
                    ])
                    await replaceForBatchDemand(target, intent: ready.intent)
                }
                return
            }
        }
        guard demandCount > replacementAttemptedDemand || replacementRetryAt.map({ now >= $0 }) == true else { return }
        // A cooldown or temporarily unavailable plan must not suppress stable
        // sustained demand forever. Retry at a bounded cadence, not every poll.
        replacementAttemptedDemand = demandCount
        replacementRetryAt = now.advanced(by: replacementRetryDelay)
        let demand = DistributedLocalBatchDemand(generationID: target.id,
            waitingRequests: waiting.count, activeRequests: target.pins.count, currentCapacity: target.capacity,
            publicModelID: binding.publicModelID, runtimeModelID: binding.runtimeModelID,
            artifactSHA256: binding.artifactSHA256, configurationSHA256: binding.configurationSHA256,
            maximumPromptTokens: binding.maxPromptTokens, maximumOutputTokens: binding.maxOutputTokens,
            maximumContextTokens: binding.maxContextTokens, requestTimeout: binding.requestTimeout)
        replacementTask = Task {
            defer { replacementTask = nil }
            let intent: DistributedLocalBatchReplacement
            do {
                guard let proposed = try await replacementPlanner(demand) else { return }
                try Task.checkCancellation()
                guard generation === target, phase == .serving, teardownTask == nil,
                      proposed.requestedCapacity > target.capacity,
                      proposed.requestedCapacity <= DistributedRequestQueue.maximumLanes else { return }
                guard !waiting.isEmpty, waiting.count + target.pins.count > target.capacity else {
                    readyBatchReplacement = .init(generationID: target.id,
                        expiresAt: ContinuousClock.now.advanced(by: min(.seconds(30), replacementRetryDelay)),
                        intent: proposed)
                    clusterObservabilityLog(.info, "cluster.batch_replan retain_ready", [
                        "generation": target.id.uuidString.lowercased(),
                        "requested_lanes": String(proposed.requestedCapacity),
                    ])
                    return
                }
                intent = proposed
            } catch { return } // Planning failure leaves the current owner serving.
            await replaceForBatchDemand(target, intent: intent)
        }
    }

    private func replaceForBatchDemand(_ previous: DistributedLocalServerGeneration,
                                       intent: DistributedLocalBatchReplacement) async {
        readyBatchReplacement = nil
        let previousBinding = DistributedLocalSessionBinding(previous.session)
        let previousCapacity = previous.capacity
        var restored = false
        phase = .reconfiguring
        monitorTask?.cancel(); monitorTask = nil
        do {
            // No new acquisition enters the previous generation from here on.
            // Existing pins, cancellation hooks and native request deadlines
            // remain bound to it until their ordinary retirement finishes.
            while true {
                try requirePreparing(previous, phase: .reconfiguring)
                guard previous.session.status == .ready, !previous.session.httpSessionInvalid else {
                    throw DistributedLocalServerError.startupInterrupted
                }
                let active = await previous.entry?.engineV2Bridge?.activeRequestCount() ?? 0
                if previous.pins.isEmpty && active == 0 { break }
                try await Task.sleep(for: DistributedRequestQueue.pollInterval)
            }
            try await retireForReplacement(previous)
            try requirePreparing(previous, phase: .reconfiguring)
            do {
                try await installReplacement(intent.makeSession, capacity: intent.requestedCapacity)
            } catch {
                try Task.checkCancellation()
                guard teardownTask == nil, phase == .reconfiguring,
                      let restore = intent.restorePreviousSession else { throw error }
                // A factory failure leaves `previous` selected; a start failure
                // leaves its new generation selected. Either must prove release.
                try await retireForReplacement(generation)
                try Task.checkCancellation()
                guard teardownTask == nil else { throw DistributedLocalServerError.startupInterrupted }
                try await installReplacement(restore, capacity: previousCapacity, exactBinding: previousBinding)
                restored = true
            }
            try Task.checkCancellation()
            guard teardownTask == nil, phase == .reconfiguring else {
                throw DistributedLocalServerError.startupInterrupted
            }
            phase = .serving
            let pid = ProcessInfo.processInfo.processIdentifier
            var fields = ["requested_lanes": String(intent.requestedCapacity),
                "effective_lanes": String(generation.capacity), "pid": String(pid),
                "generation": generation.id.uuidString.lowercased()]
            if let started = ClusterProcessTable.startTime(of: pid) { fields["process_started_at"] = String(started) }
            if let installed = generation.session.httpDiagnosticObservation?.binding {
                fields["setup_sha256"] = installed.configurationSHA256
                fields["mode"] = installed.generationMode.rawValue
            }
            clusterObservabilityLog(.info, "cluster.batch_replan \(restored ? "restored" : "activated") lanes=\(generation.capacity)", fields)
            startSessionMonitor(generation)
        } catch {
            if teardownTask == nil {
                failed = true
                recordLaunchFailure(error, target: generation)
                beginTeardown(drainUntil: nil)
            }
        }
    }

    /// The factory is allowed to prepare metadata only after the prior owner
    /// has fully retired. Retain its result before checking cancellation, so a
    /// simultaneous stop still joins and cleans up that exact fresh session.
    private func installReplacement(
        _ makeSession: @Sendable () async throws -> any DistributedLocalServerSession,
        capacity: Int, exactBinding: DistributedLocalSessionBinding? = nil
    ) async throws {
        let nextSession = try await makeSession()
        let next = DistributedLocalServerGeneration(session: nextSession,
            responseLimit: queue.responseLimit, responses: generation.responses, permitsPlacementChange: true)
        generation = next
        try requirePreparing(next, phase: .reconfiguring)
        if let exactBinding, DistributedLocalSessionBinding(nextSession) != exactBinding {
            throw DistributedLocalServerError.replacementIdentityChanged
        }
        try await prepareGeneration(next, phase: .reconfiguring)
        guard next.capacity == capacity, nextSession.readiness() != nil else {
            throw DistributedLocalServerError.replacementCapacityChanged
        }
    }

    private func retireForReplacement(_ target: DistributedLocalServerGeneration) async throws {
        guard target.pins.isEmpty else { throw DistributedLocalServerError.replacementCleanupUnresolved }
        if target.session.status != .released {
            _ = await target.session.drain(until: DispatchTime.now().uptimeNanoseconds + 30_000_000_000)
        }
        await target.session.shutdown()
        await target.ownerStopTask?.value
        await target.entry?.engineV2Bridge?.shutdown()
        guard target.pins.isEmpty, target.session.httpCanRotate, target.session.status == .released else {
            throw DistributedLocalServerError.replacementCleanupUnresolved
        }
        target.entry = nil
    }
}
