import Foundation

extension CoordinatorClient {
    internal func hasRegisteredConnection() -> Bool {
        sessionRegistered && !shutdownRequested && nwConnection != nil
    }

    /// FIFO barrier behind all queued terminals. The coordinator acknowledges
    /// only after processing them and fencing its final dispatch handoff.
    /// A dropped connection/unsupported coordinator never counts as a drain.
    public func acknowledgeDrain(timeout: Duration) async -> Bool {
        await prepareModelSwitch(timeout: timeout) != nil
    }

    /// Returns a connection-scoped settled barrier for an inventory replacement.
    public func prepareModelSwitch(timeout: Duration) async -> String? {
        guard hasRegisteredConnection(), let connection = nwConnection else { return nil }
        acknowledgedSwitchDrain = nil
        let id = UUID().uuidString
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        drainAcknowledgements[id] = continuation
        defer {
            drainAcknowledgements.removeValue(forKey: id)?.finish()
        }
        chunkSender.flush()
        outboundRouter.yield(.drainBarrier(id))
        let acknowledged = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await result in stream { return result }
                return false
            }
            group.addTask {
                try? await taskSleep(timeout)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        guard acknowledged, nwConnection === connection, hasRegisteredConnection() else { return nil }
        acknowledgedSwitchDrain = id
        return id
    }

    /// ProviderLoop calls this only after handling all earlier queued events.
    /// This closes the receive-queue race with pre-boundary inference frames.
    internal func completeDrainAcknowledgement(_ id: String) {
        drainAcknowledgements.removeValue(forKey: id)?.yield(true)
    }

    internal func failDrainBarriers() {
        acknowledgedSwitchDrain = nil
        for continuation in drainAcknowledgements.values {
            continuation.yield(false)
            continuation.finish()
        }
        drainAcknowledgements.removeAll()
    }
}
