import SwiftUI

/// Reuses the CLI-backed account step without entering machine enrollment or
/// model setup. Closing cancels only this attempt; the CLI preserves the old
/// credential until fresh browser authorization is successfully published.
struct AccountReconnectView: View {
    let identity: MachineIdentity
    let onLinked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var flow = OnboardingFlowModel(startingAt: .account)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Refresh your account link")
                    .font(DarkbloomTheme.chivo(18, weight: .medium))
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            AccountLinkStepView(flow: flow, identity: identity, isCompact: true)
        }
        .padding(28)
        .frame(width: 900)
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.canvas)
        .onChange(of: flow.accountPhase) { _, phase in
            if phase == .linked {
                onLinked()
                dismiss()
            }
        }
        .onDisappear { flow.cancelPendingOperations() }
    }
}
