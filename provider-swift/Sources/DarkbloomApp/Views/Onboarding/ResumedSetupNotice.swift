import SwiftUI

struct ResumedSetupNotice: View {
    let state: ResumeReconciliationState

    private var title: String {
        switch state {
        case .required, .rechecking: "RECHECKING SETUP"
        case .reconciled: "SETUP RECHECKED"
        case .unavailable: "RECHECK UNAVAILABLE"
        case .notNeeded: "SETUP PREVIEW"
        }
    }

    private var message: String {
        switch state {
        case .required, .rechecking:
            "Darkbloom is checking the live account, profile, model, provider endpoint, and trust before restored status can advance."
        case .reconciled:
            "Saved progress was replaced with the latest live machine state."
        case .unavailable:
            "Saved status could not be reconciled. Return to welcome and start over, or try again when live services are available."
        case .notNeeded:
            "Setup will use current machine state rather than saved success flags."
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state == .reconciled ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .foregroundStyle(DarkbloomTheme.accent)

            Text(title)
                .font(DarkbloomTheme.chivo(9, weight: .medium))
                .tracking(0.9)

            Text(message)
                .font(DarkbloomTheme.chivo(11))
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(DarkbloomTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(message)")
    }
}
