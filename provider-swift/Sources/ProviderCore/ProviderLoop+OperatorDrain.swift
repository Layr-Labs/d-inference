import Foundation

extension ProviderLoop {
    /// Default deadline shared by the daemon and the operator CLI. Ten minutes
    /// covers long generations without letting a wedged request leave a command
    /// waiting forever.
    public static let operatorDrainTimeout: Duration = .seconds(600)

    /// Close admission, let paid work finish, then close the coordinator so the
    /// normal `run()` teardown can release models and exit. The event loop stays
    /// alive during the wait, which is required for active streams to complete
    /// and for newly routed work to receive the retryable 503 drain response.
    public func requestOperatorShutdown(
        timeout: Duration = ProviderLoop.operatorDrainTimeout
    ) async -> OperatorDrainController.Outcome {
        guard coordinatorClient != nil else { return .unavailable }

        let me = self
        let controller = OperatorDrainController(
            dependencies: .init(
                begin: { await me.beginOperatorDrain() },
                waitForDrain: { duration in
                    await me.waitForInflightDrain(timeout: duration)
                },
                resume: { await me.resumeAfterOperatorDrainTimeout() },
                finishShutdown: { await me.finishOperatorShutdown() }
            ),
            timeout: timeout
        )
        return await controller.run()
    }

    private func beginOperatorDrain() -> Bool {
        guard !isShuttingDown,
              !isOperatorDraining,
              updatePhase == .idle
        else { return false }

        isOperatorDraining = true
        logger.info("Operator drain started; refusing new work while active inference finishes")
        writeDaemonState()
        return true
    }

    private func resumeAfterOperatorDrainTimeout() async {
        guard isOperatorDraining, !isShuttingDown else { return }
        isOperatorDraining = false
        logger.warning("Operator drain timed out; restart cancelled and admission reopened")
        writeDaemonState()
        await replayDeferredDesiredModels(after: "operator drain")
    }

    private func finishOperatorShutdown() async {
        guard isOperatorDraining else { return }
        // Keep the admission gate closed across the coordinator shutdown await.
        // No request can enter between the final zero-count observation and the
        // WebSocket close.
        isShuttingDown = true
        writeDaemonState()
        logger.info("Operator drain complete; closing coordinator connection")
        await coordinatorClient?.shutdown()
    }
}
