import SwiftUI

struct SetupMacButton: View {
    let action: () -> Void
    var onHoverChanged: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button("Set up this Mac", action: action)
            .font(DarkbloomTheme.chivo(15, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DarkbloomTheme.accent.opacity(isEnabled ? 1 : 0.45))
                    .brightness(isHovered ? 0.035 : 0)
            }
            .shadow(
                color: DarkbloomTheme.accent.opacity(isHovered ? 0.18 : 0.08),
                radius: isHovered ? 16 : 9,
                y: isHovered ? 7 : 4
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .buttonStyle(SetupMacPressStyle(reduceMotion: reduceMotion))
            .onHover { isHovering in
                isHovered = isHovering
                onHoverChanged(isHovering)
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: isHovered
            )
            .accessibilityHint("Starts setup for this Mac")
    }
}

struct HowItWorksButton: View {
    let width: CGFloat
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isHovered ? DarkbloomTheme.ink : .clear)
                    Circle()
                        .stroke(DarkbloomTheme.ink.opacity(isHovered ? 1 : 0.72), lineWidth: 1)
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHovered ? .white : DarkbloomTheme.ink)
                        .offset(x: 1)
                }
                .frame(width: 32, height: 32)

                Text("How it works")
                    .font(DarkbloomTheme.chivo(14, weight: .medium))
                    .foregroundStyle(DarkbloomTheme.ink)
            }
            .opacity(isHovered ? 1 : 0.78)
            .frame(width: width, height: 46, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SecondaryActionPressStyle(reduceMotion: reduceMotion))
        .onHover { isHovered = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isHovered
        )
        .accessibilityHint("Explains private AI and idle network capacity")
    }
}

private struct SetupMacPressStyle: ButtonStyle {
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

private struct SecondaryActionPressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.97)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.1),
                value: configuration.isPressed
            )
    }
}
