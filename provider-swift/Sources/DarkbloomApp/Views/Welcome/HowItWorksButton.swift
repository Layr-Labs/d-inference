import SwiftUI

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
