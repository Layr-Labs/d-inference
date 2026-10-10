import Foundation

extension DistributedLocalServer {
    func beginQuotaRotation(_ target: DistributedLocalServerGeneration) {
        guard generation === target, phase == .serving, rotationTask == nil,
              replacementSessionFactory != nil, target.session.httpSessionExhausted,
              !target.session.httpSessionInvalid else { return }
        phase = .rotating
        responseRouter.withdraw(target.responses)
        rotationTask = Task { await self.rotateAfterQuota(target) }
    }

    private func rotateAfterQuota(_ target: DistributedLocalServerGeneration) async {
        defer { rotationTask = nil }
        do {
            try requirePreparing(target, phase: .rotating)
            guard let deadline = target.session.lifetimeDeadlineUptimeNanoseconds,
                  let factory = replacementSessionFactory else {
                throw DistributedLocalServerError.lifetimeExpired
            }
            // Begin the exact owner's drain independently of HTTP delivery.
            // Its existing request retirement/release can unblock the old bridge
            // pump; waiting for delivery before this would risk a cycle.
            let ownerStop = Task {
                _ = await target.session.drain(until: deadline)
                await target.session.shutdown()
            }
            target.ownerStopTask = ownerStop
            while target.pin != nil || target.responses.hasActiveResponse {
                try requirePreparing(target, phase: .rotating)
                if DispatchTime.now().uptimeNanoseconds >= deadline {
                    throw DistributedLocalServerError.lifetimeExpired
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            try requirePreparing(target, phase: .rotating)
            let bridge = target.entry?.engineV2Bridge
            let bridgeStop = Task { await bridge?.shutdown() }
            await ownerStop.value
            _ = await bridgeStop.value
            try requirePreparing(target, phase: .rotating)
            guard target.pin == nil, !target.responses.hasActiveResponse,
                  target.session.httpCanRotate, target.session.status == .released else {
                throw DistributedLocalServerError.replacementNotReleased
            }
            target.entry = nil
            let candidate = try await factory()
            // Retain even an invalid or late-returned candidate before throwing.
            // Stop joins this task and then captures the retained generation.
            let replacement = DistributedLocalServerGeneration(session: candidate)
            generation = replacement
            try requirePreparing(replacement, phase: .rotating)
            guard candidate.status == .prepared else {
                throw DistributedLocalServerError.replacementNotPrepared
            }
            guard !seenMembershipEpochs.contains(candidate.expectedIdentity.membershipEpoch),
                  DistributedLocalSessionBinding(candidate) == binding else {
                throw DistributedLocalServerError.replacementIdentityChanged
            }
            seenMembershipEpochs.insert(candidate.expectedIdentity.membershipEpoch)
            let lifetime = try await prepareGeneration(replacement, phase: .rotating)
            try requirePreparing(replacement, phase: .rotating)
            guard boundPort != nil else { throw DistributedLocalServerError.bindFailed }
            try responseRouter.publish(replacement.responses)
            phase = .serving
            startLifetimeMonitor(replacement, deadline: lifetime)
        } catch {
            // Explicit stop already owns its outcome. Any independent rotation
            // failure remains failed even if subsequent cleanup succeeds.
            if teardownTask == nil { failed = true }
            beginTeardown(drainUntil: nil)
        }
    }
}
