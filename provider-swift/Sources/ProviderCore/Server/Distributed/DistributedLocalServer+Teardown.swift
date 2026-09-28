import Foundation

extension DistributedLocalServer {
    func beginTeardown(drainUntil: UInt64?) {
        if phase == .stopped { return }
        removeDiscovery()
        responseRouter.close()
        let target = generation
        target.responses.closeAdmissions()
        if teardownTask != nil {
            if drainUntil == nil {
                if phase != .quarantined { phase = .stopping }
                target.responses.beginDeliveryGrace()
                Task { _ = await target.session.stop(until: DispatchTime.now().uptimeNanoseconds) }
            }
            return
        }
        if phase != .quarantined { phase = drainUntil == nil ? .stopping : .draining }
        startupTask?.cancel()
        rotationTask?.cancel()
        if drainUntil == nil {
            target.responses.beginDeliveryGrace()
            Task { _ = await target.session.stop(until: DispatchTime.now().uptimeNanoseconds) }
        }
        teardownTask = Task { await self.finishTeardown(drainUntil: drainUntil) }
    }

    private func finishTeardown(drainUntil: UInt64?) async {
        // Join preparation before capturing the retained session: a factory may
        // return a replacement after stop and it must still be cleaned up here.
        _ = await startupTask?.result
        _ = await rotationTask?.value
        let target = generation
        target.responses.closeAdmissions()
        if let drainUntil { _ = await target.session.drain(until: drainUntil) }
        target.responses.beginDeliveryGrace()
        let ownerStop = Task { await target.session.shutdown() }
        await target.responses.waitForDelivery()
        target.responses.abort()
        serviceTask?.cancel()
        let bridge = target.entry?.engineV2Bridge
        let engineStop = Task { await bridge?.shutdown() }
        await ownerStop.value
        _ = await target.ownerStopTask?.value
        _ = await engineStop.value
        _ = await serviceTask?.value
        target.responses.listenerStopped()
        if target.pin != nil {
            await withCheckedContinuation { target.pinWaiters.append($0) }
        }
        lifetimeTask?.cancel(); lifetimeTask = nil
        removeDiscovery()
        boundPort = nil; serviceTask = nil; startupTask = nil
        if target.session.httpCanRotate && target.session.status == .released {
            target.entry = nil; phase = .stopped
        } else {
            phase = .quarantined
        }
        teardownTask = nil
        publishStopOutcome()
    }
}
