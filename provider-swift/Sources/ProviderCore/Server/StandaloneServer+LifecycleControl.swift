import Foundation

extension StandaloneServer {
    /// CLI-only opt-in; embedded/test servers never write the operator's state.
    public func startLifecycleControl(stateFile: URL = DaemonStateFile.path()) {
        guard lifecycleControlTask == nil, let identity = ProcessIdentity.current() else { return }
        let mailbox = LifecycleMailbox(identity: identity, directory: stateFile.deletingLastPathComponent().appendingPathComponent("lifecycle"))
        lifecycleControlTask = Task { [weak self] in
            var handled: String?
            while !Task.isCancelled {
                guard let self else { return }
                if let request = mailbox.readRequest(), request.id != handled, request.isValid(for: identity) {
                    handled = request.id
                    Task { _ = await self.drainForLifecycle(request) }
                }
                await self.publishLifecycleControl(identity: identity, mailbox: mailbox, stateFile: stateFile)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func publishLifecycleControl(identity: ProcessIdentity, mailbox: LifecycleMailbox, stateFile: URL) {
        try? mailbox.writeStatus(lifecycleStatus)
        DaemonStateFile.write(.init(pid: identity.pid, processIdentity: identity, version: ProviderCore.version,
            writtenAt: Date().timeIntervalSince1970, startedAt: Double(identity.startTimeMicros) / 1_000_000,
            inferenceActive: responseTracker.activeCount > 0, lifecycle: lifecycleStatus), to: stateFile)
    }
}
