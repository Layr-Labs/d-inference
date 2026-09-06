import SwiftUI

struct LinkAnotherMacSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Link another Mac")
                    .font(DarkbloomTheme.chivo(24, weight: .medium))
                    .tracking(-0.45)
                Text("Set up Darkbloom on the other Mac with the same account. It will appear here after its first verified connection.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                step(
                    1,
                    title: "Open Darkbloom on the other Mac",
                    detail: "Choose Set up this Mac, then sign in with this Darkbloom account."
                )
                step(
                    2,
                    title: "Install its enrollment profile",
                    detail: "Open System Settings › General › Device Management and approve the downloaded profile with administrator authentication."
                )
                step(
                    3,
                    title: "Return to Darkbloom",
                    detail: "Darkbloom verifies the profile and finishes linking the Mac. No action is needed on this Mac."
                )
            }

            Label {
                Text("The Darkbloom profile is read-only. It cannot erase or lock the Mac, install apps, or change its settings.")
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(DarkbloomTheme.accent)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .background(DarkbloomTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func step(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number.formatted())
                .font(.caption.weight(.semibold))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 26, height: 26)
                .background(DarkbloomTheme.accent.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }
}
