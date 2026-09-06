/// Process liveness and trust are separate observations. Neither establishes
/// routable capacity, so an idle provider is never advertised as serving work.
struct ProviderMenuBarNetworkPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let tone: MenuBarStatusTone

    init(snapshot: ProviderSnapshot) {
        let status = Self.status(snapshot)
        title = status.0
        detail = status.1
        tone = status.2
    }

    private static func status(_ snapshot: ProviderSnapshot) -> (String, String, MenuBarStatusTone) {
        if snapshot.isStale && snapshot.isRunning && !snapshot.runState.isTransitioning {
            return ("Sharing status unknown", "The provider’s last report is out of date. Open Network to check.", .attention)
        }

        switch snapshot.runState {
        case .online:
            switch snapshot.trust.state {
            case .verified:
                return ("Network provider running", "This Mac is verified. No active inference is reported.", .neutral)
            case .pending:
                return ("Network verification pending", "The provider is running. Verification is still in progress.", .neutral)
            case .failed:
                return ("Network verification failed", "The provider is running but needs attention in Network.", .attention)
            case .unknown:
                return ("Network provider running", "Verification is not reported. Check Network for sharing status.", .neutral)
            }
        case .serving:
            return ("Handling requests", "The provider reports active inference. It can handle local and network requests.", .active)
        case .paused:
            return ("Network sharing paused", "This Mac’s network provider is stopped. Local AI is separate.", .neutral)
        case .scheduledOff:
            return ("Outside sharing schedule", "Network sharing resumes in the next availability window.", .neutral)
        case .attention:
            return ("Network needs attention", "Check the sharing provider’s verification and models in Network.", .attention)
        case .stale:
            return ("Sharing status unknown", "The provider’s last report is out of date. Open Network to check.", .attention)
        case .starting:
            return ("Starting network provider", "Preparing this Mac for network sharing.", .neutral)
        case .stopping:
            return ("Pausing network sharing", "Waiting for the network provider to stop.", .neutral)
        case .restarting:
            return ("Restarting network provider", "Waiting for the provider to restart and report its status.", .neutral)
        }
    }
}
