import Foundation

extension ProviderLoop {
    /// Prompt completion can precede output and terminal delivery by seconds.
    /// Rebuild from the current runtime roster, never from a callback's slot:
    /// a retiring/replaced bridge cannot republish its stale measurements.
    internal func startPerformanceRefreshMonitor() {
        performanceRefreshTask?.cancel()
        let changes = engineV2Runtime.performanceUpdates.changes()
        performanceRefreshTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { break }
                await self.refreshPerformanceCapacity()
            }
        }
    }

    internal func stopPerformanceRefreshMonitor() async {
        let task = performanceRefreshTask
        performanceRefreshTask = nil
        task?.cancel()
        await task?.value
    }

    private func refreshPerformanceCapacity() async {
        guard !isShuttingDown else { return }
        await updateAggregateCapacity()
    }
}
