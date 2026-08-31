import Foundation

extension ProviderLoop {
    internal func handleCancellation(
        requestId: String,
        receivedFromCoordinator: Bool = true
    ) async {
        let hadInflight = inflightTasks[requestId] != nil
        if receivedFromCoordinator, hadInflight {
            stats.incrementCancellationsReceived()
        }
        await inferenceWorkerClient.cancel(requestIdentifier: requestId)
        if !receivedFromCoordinator {
            inflightTasks.removeValue(forKey: requestId)?.cancel()
            completedBeforeTaskRegistration.remove(requestId)
            await updateAggregateCapacity()
        }
    }

    internal func cancelAllInflight() async {
        for requestId in Array(inflightTasks.keys) {
            await handleCancellation(
                requestId: requestId,
                receivedFromCoordinator: false)
        }
        inflightTasks.removeAll()
        completedBeforeTaskRegistration.removeAll()
    }

    internal func finishInflightRequest(requestId: String) async {
        if inflightTasks.removeValue(forKey: requestId) == nil {
            completedBeforeTaskRegistration.insert(requestId)
        }
        await updateAggregateCapacity()
    }

    internal var hasInflightWork: Bool {
        !inflightTasks.isEmpty
    }

    internal func waitForInflightDrain(timeout: Duration) async -> Bool {
        guard hasInflightWork else { return true }
        let started = ContinuousClock.now
        while hasInflightWork {
            if Task.isCancelled || ContinuousClock.now - started >= timeout {
                return false
            }
            do {
                try await taskSleep(.milliseconds(250))
            } catch {
                return false
            }
        }
        return true
    }
}
