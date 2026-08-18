import SwiftUI

struct SettingsPreviewNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 30, height: 30)
                .background(DarkbloomTheme.accent.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Settings UI preview")
                    .font(.system(size: 12, weight: .semibold))

                Text("Controls save sample choices in this preview only. They are not applied to a Darkbloom provider, macOS, or your account.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text("PREVIEW")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(DarkbloomTheme.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DarkbloomTheme.accent.opacity(0.09), in: Capsule())
        }
        .padding(12)
        .background(DarkbloomTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DarkbloomTheme.accent.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Settings UI preview")
        .accessibilityValue("Controls save sample choices only and are not applied to a provider, macOS, or an account.")
    }
}
