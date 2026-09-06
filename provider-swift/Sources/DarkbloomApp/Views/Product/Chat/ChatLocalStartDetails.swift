import SwiftUI

struct ChatLocalStartDetails: View {
    let summary: String
    let detail: String

    var body: some View {
        DisclosureGroup {
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        } label: {
            Text(summary)
                .font(DarkbloomTheme.chivo(12))
                .foregroundStyle(StudioPalette.secondaryInk)
        }
    }
}

/// Presentation only. Readiness and all recovery actions belong to the shared
/// LocalAPIStartController, not to these labels.
enum ChatLocalStartCopy {
    static func session(_ state: LocalAPIStartState, models: [ModelSummary]) -> String {
        switch state {
        case .starting(let id), .waitingForEndpoint(let id):
            "Starting \(models.first { $0.id == id }?.displayName ?? id)…"
        case .ready:
            "Ready on this Mac. The first reply may take a little longer."
        case .cancelling:
            "Ending your local session…"
        case .failed(let error):
            failure(error)
        case .cancelled:
            "Local session ended."
        case .idle:
            "Choose a model to begin."
        }
    }

    static func conflict(_ conflict: LocalAPIStartConflict) -> String {
        switch conflict {
        case .localEndpoint: "An existing local session needs a connection check."
        case .providerRunning: "Your provider is already running on this Mac."
        case .providerTransitioning: "Your provider is changing state. Give it a moment."
        case .providerStateUncertain: "Check this Mac’s provider before starting a model."
        }
    }

    static func failure(_ error: LocalAPIStartError) -> String {
        switch error {
        case .readinessTimedOut: "The model is taking longer to become ready."
        case .shutdownTimedOut: "The session hasn’t stopped yet. Keep Darkbloom open."
        case .fixtureMode: "This sample can’t start a local session."
        case .modelNotInstalled, .modelUnavailable: "Choose another installed model."
        case .conflict(let conflict): self.conflict(conflict)
        case .nonReplacingLaunchUnavailable: "Local start needs attention."
        case .cli, .launchFailed, .processExited: "The local session couldn’t start."
        }
    }
}
