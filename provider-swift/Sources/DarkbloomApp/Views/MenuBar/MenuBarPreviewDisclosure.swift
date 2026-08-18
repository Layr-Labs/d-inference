import SwiftUI

struct MenuBarPreviewDisclosure: View {
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "eye.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 24, height: 24)
                .background(DarkbloomTheme.accent.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("UI PREVIEW")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(DarkbloomTheme.accent)

                Text("Sample status and controls only. No provider or system changes are made.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(DarkbloomTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("UI Preview. Sample status and controls only. No provider or system changes are made.")
    }
}
