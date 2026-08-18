import SwiftUI

struct ProviderStatusPresentation {
    let sidebarTitle: String
    let sidebarDetail: String
    let badgeTitle: String
    let activityTitle: String
    let activityDetail: String
    let icon: String
    let tint: Color
}

extension ProviderSnapshot {
    var statusPresentation: ProviderStatusPresentation {
        if runState == .online, trust.state != .verified {
            let detail = trust.guidance ?? trust.reason
            return ProviderStatusPresentation(
                sidebarTitle: "Needs attention",
                sidebarDetail: trust.reason,
                badgeTitle: "Needs attention",
                activityTitle: "Verification is incomplete",
                activityDetail: detail,
                icon: "exclamationmark.shield.fill",
                tint: ProductPalette.warning
            )
        }

        switch runState {
        case .online:
            return ProviderStatusPresentation(
                sidebarTitle: "Available",
                sidebarDetail: "Ready for private work",
                badgeTitle: "Idle",
                activityTitle: "Quiet and ready",
                activityDetail: "No request is using this Mac right now.",
                icon: "checkmark.circle.fill",
                tint: ProductPalette.positive
            )
        case .serving:
            return ProviderStatusPresentation(
                sidebarTitle: "Serving",
                sidebarDetail: currentModel?.displayName ?? "Private request active",
                badgeTitle: "Serving now",
                activityTitle: "Private inference is active",
                activityDetail: "Only request metadata is visible. The encrypted prompt remains private.",
                icon: "waveform.path.ecg",
                tint: DarkbloomTheme.accent
            )
        case .paused:
            return ProviderStatusPresentation(
                sidebarTitle: "Paused",
                sidebarDetail: "Offline until you resume",
                badgeTitle: "Paused",
                activityTitle: "This Mac is offline",
                activityDetail: "The provider is paused and will stay offline until you make it available.",
                icon: "pause.circle.fill",
                tint: .secondary
            )
        case .scheduledOff:
            return ProviderStatusPresentation(
                sidebarTitle: "Scheduled off",
                sidebarDetail: "Outside your schedule",
                badgeTitle: "Scheduled off",
                activityTitle: "Outside the availability window",
                activityDetail: "The provider is outside its availability schedule.",
                icon: "moon.zzz.fill",
                tint: .secondary
            )
        case .attention:
            return ProviderStatusPresentation(
                sidebarTitle: "Needs attention",
                sidebarDetail: trust.reason,
                badgeTitle: "Needs attention",
                activityTitle: "Network work is waiting",
                activityDetail: trust.guidance ?? lastProblem?.detail ?? trust.reason,
                icon: "exclamationmark.triangle.fill",
                tint: ProductPalette.warning
            )
        case .stale:
            return ProviderStatusPresentation(
                sidebarTitle: "Not responding",
                sidebarDetail: "Last state is out of date",
                badgeTitle: "Not responding",
                activityTitle: "Provider state is out of date",
                activityDetail: "The provider has not checked in recently.",
                icon: "exclamationmark.octagon.fill",
                tint: ProductPalette.critical
            )
        case .starting:
            return transitioningStatus(
                title: "Starting",
                activityTitle: "Preparing private inference",
                detail: "Preparing models and reconnecting securely.",
                icon: "ellipsis.circle.fill"
            )
        case .stopping:
            return transitioningStatus(
                title: "Going offline",
                activityTitle: "Releasing provider resources",
                detail: "Finishing the transition and unloading provider resources.",
                icon: "ellipsis.circle.fill"
            )
        case .restarting:
            return transitioningStatus(
                title: "Restarting",
                activityTitle: "Restarting the provider",
                detail: "Darkbloom is restarting its local provider.",
                icon: "arrow.clockwise.circle.fill"
            )
        }
    }

    private func transitioningStatus(
        title: String,
        activityTitle: String,
        detail: String,
        icon: String
    ) -> ProviderStatusPresentation {
        ProviderStatusPresentation(
            sidebarTitle: title,
            sidebarDetail: "Please wait",
            badgeTitle: title,
            activityTitle: activityTitle,
            activityDetail: detail,
            icon: icon,
            tint: DarkbloomTheme.accent
        )
    }
}
