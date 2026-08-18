import SwiftUI

struct EnrollmentRightsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 17, weight: .medium))
                Text("DARKBLOOM PROVIDER ENROLLMENT")
                    .font(DarkbloomTheme.chivo(9, weight: .medium))
                    .tracking(0.95)
                Spacer()
                Text("READ-ONLY")
                    .font(DarkbloomTheme.chivo(8, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(DarkbloomTheme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(DarkbloomTheme.accent.opacity(0.09), in: Capsule())
            }

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.09))
                .frame(height: 1)
                .padding(.vertical, 18)

            PermissionGroup(
                title: "CAN VERIFY",
                symbol: "checkmark",
                items: ["Genuine Apple hardware", "SIP and Secure Boot", "System integrity", "Profile presence"],
                color: DarkbloomTheme.accent
            )

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.07))
                .frame(height: 1)
                .padding(.vertical, 15)

            PermissionGroup(
                title: "CANNOT",
                symbol: "minus",
                items: ["Erase or lock this Mac", "Install apps", "Change settings", "Read prompts or files"],
                color: DarkbloomTheme.ink.opacity(0.35)
            )

            Spacer(minLength: 12)

            Text("Remove anytime in System Settings  ›  General  ›  Device Management")
                .font(DarkbloomTheme.chivo(9))
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.4))
        }
        .padding(24)
        .frame(width: 382, height: 405, alignment: .topLeading)
        .onboardingPanel()
    }
}

private struct PermissionGroup: View {
    let title: String
    let symbol: String
    let items: [String]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(DarkbloomTheme.chivo(8, weight: .medium))
                .tracking(1)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.4))

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(color)
                            .frame(width: 15, height: 15)
                            .overlay {
                                Image(systemName: symbol)
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        Text(item)
                            .font(DarkbloomTheme.chivo(10))
                            .lineSpacing(2)
                            .foregroundStyle(DarkbloomTheme.ink.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
