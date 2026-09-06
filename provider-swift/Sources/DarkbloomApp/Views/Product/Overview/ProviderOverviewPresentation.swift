import SwiftUI

struct ProviderStatePresentation {
    let overline: String
    let title: String
    let detail: String
    let badgeTitle: String
    let badgeIcon: String
    let primaryActionTitle: String
    let tint: Color
    let fieldFocus: CGFloat
    let fieldActivity: CGFloat
}

extension ProviderSnapshot {
    var presentation: ProviderStatePresentation {
        let status = statusPresentation

        if runState == .online, trust.state != .verified {
            return ProviderStatePresentation(
                overline: "VERIFICATION INCOMPLETE",
                title: "One more check before network work.",
                detail: trust.guidance ?? trust.reason,
                badgeTitle: status.badgeTitle,
                badgeIcon: status.icon,
                primaryActionTitle: "Review verification",
                tint: status.tint,
                fieldFocus: 0.18,
                fieldActivity: 0.08
            )
        }

        switch runState {
        case .online:
            return state(
                "AVAILABLE · IDLE",
                title: "Ready when work arrives.",
                detail: "This Mac is available to accept encrypted work from the Darkbloom network.",
                badge: status.sidebarTitle,
                icon: status.icon,
                action: "Take offline",
                tint: status.tint,
                focus: 0.30,
                activity: 0.34
            )
        case .serving:
            return state(
                "SERVING PRIVATELY",
                title: "Private work is in bloom.",
                detail: "Encrypted network requests are being processed on this Mac. Activity shows counts and timing without conversation content.",
                badge: "Serving",
                icon: "waveform.path.ecg",
                action: "Take offline",
                tint: DarkbloomTheme.accent,
                focus: 0.62,
                activity: 0.82
            )
        case .paused:
            return state(
                "NETWORK PAUSED",
                title: "Available when you choose.",
                detail: "Start local AI from Local API, or make this Mac available for network work.",
                badge: "Paused",
                icon: "pause.circle.fill",
                action: "Make available",
                tint: .secondary,
                focus: 0.08,
                activity: 0.02
            )
        case .scheduledOff:
            return state(
                "OUTSIDE YOUR SCHEDULE",
                title: "Resting until the next window.",
                detail: "Network work is paused outside the schedule you chose.",
                badge: "Scheduled off",
                icon: "moon.zzz.fill",
                action: "Review schedule",
                tint: .secondary,
                focus: 0.10,
                activity: 0.03
            )
        case .attention:
            return state(
                "ACTION NEEDED",
                title: "One step needs your attention.",
                detail: lastProblem?.detail ?? trust.guidance ?? "Review this Mac’s health before accepting network work.",
                badge: "Needs attention",
                icon: "exclamationmark.triangle.fill",
                action: "Review verification",
                tint: ProductPalette.warning,
                focus: 0.18,
                activity: 0.08
            )
        case .stale:
            return state(
                "NOT RESPONDING",
                title: "The network provider needs attention.",
                detail: "Its last report is out of date. Restart the network provider to request a fresh connection.",
                badge: "Not responding",
                icon: "exclamationmark.octagon.fill",
                action: "Restart network provider",
                tint: ProductPalette.critical,
                focus: 0.12,
                activity: 0.01
            )
        case .starting:
            return transitioning("STARTING", title: "Waking this Mac.", detail: "Preparing models and reconnecting securely…")
        case .stopping:
            return transitioning("GOING OFFLINE", title: "Releasing this Mac.", detail: "Finishing the transition and unloading provider resources…")
        case .restarting:
            return transitioning("RESTARTING", title: "Beginning again, cleanly.", detail: "Darkbloom is restarting its local provider…")
        }
    }

    private func state(
        _ overline: String,
        title: String,
        detail: String,
        badge: String,
        icon: String,
        action: String,
        tint: Color,
        focus: CGFloat,
        activity: CGFloat
    ) -> ProviderStatePresentation {
        ProviderStatePresentation(
            overline: overline,
            title: title,
            detail: detail,
            badgeTitle: badge,
            badgeIcon: icon,
            primaryActionTitle: action,
            tint: tint,
            fieldFocus: focus,
            fieldActivity: activity
        )
    }

    private func transitioning(_ overline: String, title: String, detail: String) -> ProviderStatePresentation {
        state(
            overline,
            title: title,
            detail: detail,
            badge: "Working",
            icon: "ellipsis.circle.fill",
            action: "Working…",
            tint: DarkbloomTheme.accent,
            focus: 0.38,
            activity: 0.42
        )
    }
}
