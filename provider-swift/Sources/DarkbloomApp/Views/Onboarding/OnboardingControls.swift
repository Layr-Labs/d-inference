import SwiftUI

struct OnboardingPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isWorking = false
    var isDisabled = false
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                Text(title)

                if let systemImage, !isWorking {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .font(DarkbloomTheme.chivo(15, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DarkbloomTheme.accent.opacity(isDisabled ? 0.38 : 1))
                    .brightness(isHovered && !isDisabled ? 0.035 : 0)
            }
            .shadow(
                color: DarkbloomTheme.accent.opacity(isHovered && !isDisabled ? 0.18 : 0.08),
                radius: isHovered ? 16 : 9,
                y: isHovered ? 7 : 4
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(OnboardingPressStyle(reduceMotion: reduceMotion))
        .disabled(isDisabled || isWorking)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}

struct OnboardingQuietButton: View {
    let title: String
    var systemImage: String? = nil
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .font(DarkbloomTheme.chivo(13, weight: .medium))
            .foregroundStyle(DarkbloomTheme.ink.opacity(isHovered ? 0.9 : 0.5))
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .accessibilityIdentifier(accessibilityIdentifier ?? title)
    }
}

private struct OnboardingPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.985)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}

struct OnboardingPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 24

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.white.opacity(0.56))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.9), lineWidth: 1)
                    }
            }
            .shadow(color: DarkbloomTheme.accent.opacity(0.12), radius: 34, y: 20)
            .shadow(color: .black.opacity(0.04), radius: 18, y: 10)
    }
}

extension View {
    func onboardingPanel(cornerRadius: CGFloat = 24) -> some View {
        modifier(OnboardingPanelModifier(cornerRadius: cornerRadius))
    }
}
