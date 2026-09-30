import Foundation

extension ProviderLoop {
    /// Local and coordinator work share this budget. Pre-submit acquisition and
    /// delayed retirement can change it without changing any engine slot count.
    internal func startServiceAllowanceRefreshMonitor() {
        serviceAllowanceRefreshTask?.cancel()
        let changes = kvBudget.serviceBudget.changes()
        serviceAllowanceRefreshTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled, let self else { break }
                await self.refreshServiceAllowanceCapacity()
            }
        }
    }

    internal func stopServiceAllowanceRefreshMonitor() async {
        let task = serviceAllowanceRefreshTask
        serviceAllowanceRefreshTask = nil
        task?.cancel()
        await task?.value
    }

    private func refreshServiceAllowanceCapacity() async {
        guard !isShuttingDown else { return }
        await updateAggregateCapacity()
    }
}
