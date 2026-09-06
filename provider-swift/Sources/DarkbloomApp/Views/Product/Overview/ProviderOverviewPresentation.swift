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
                title: "This Mac is connected.",
                detail: "Darkbloom reports this Mac online. Requests run here when the network selects it.",
                badge: status.sidebarTitle,
                icon: status.icon,
                action: "Pause sharing",
                tint: status.tint,
                focus: 0.30,
                activity: 0.34
            )
        case .serving:
            return state(
                "SERVING PRIVATELY",
                title: "This Mac is handling requests.",
                detail: "The provider can handle both local and network requests. Activity shows counts and timing without conversation content.",
                badge: "Serving",
                icon: "waveform.path.ecg",
                action: "Pause sharing",
                tint: DarkbloomTheme.accent,
                focus: 0.62,
                activity: 0.82
            )
        case .paused:
            return state(
                "NETWORK PAUSED",
                title: "Network sharing is paused.",
                detail: "This Mac is not accepting network requests. Start sharing when you’re ready to contribute compute.",
                badge: "Paused",
                icon: "pause.circle.fill",
                action: "Start sharing",
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
            return transitioning("CONNECTING", title: "Connecting this Mac.", detail: "Preparing models and reconnecting to Darkbloom…")
        case .stopping:
            return transitioning("PAUSING", title: "Pausing network sharing.", detail: "Finishing the transition and releasing provider resources…")
        case .restarting:
            return transitioning("RECONNECTING", title: "Reconnecting to Darkbloom.", detail: "The network provider is restarting…")
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
