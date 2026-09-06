import SwiftUI

struct UIPreviewNotice: View {
    var body: some View {
        HStack(spacing: 10) {
            Label("UI PREVIEW", systemImage: "eye.fill")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(DarkbloomTheme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(DarkbloomTheme.accent.opacity(0.10), in: Capsule())

            Text("Sample data only — no provider or runtime is connected. No provider or system changes are made.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("UI Preview. Sample data only. No provider or runtime is connected, and no provider or system changes are made.")
    }
}
