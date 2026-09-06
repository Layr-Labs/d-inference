import SwiftUI

enum MenuBarStatusTone: Equatable, Sendable {
    case neutral
    case active
    case attention

    var color: Color {
        switch self {
        case .neutral: StudioPalette.secondaryInk
        case .active: StudioPalette.accent
        case .attention: ProductPalette.warning
        }
    }
}

struct MenuBarRule: View {
    var body: some View {
        Rectangle()
            .fill(StudioPalette.line)
            .frame(height: 1)
    }
}

struct MenuBarSectionHeading: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(DarkbloomTheme.chivo(16, weight: .medium))
                .tracking(-0.3)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(DarkbloomTheme.chivo(11.5))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MenuBarStatus: View {
    let title: String
    let detail: String
    let tone: MenuBarStatusTone
    var isBusy = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: tone == .attention ? "exclamationmark.circle" : "circle.fill")
                .font(.system(size: tone == .attention ? 12 : 6, weight: .medium))
                .foregroundStyle(tone.color)
                .frame(width: 12, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DarkbloomTheme.chivo(12.5, weight: .medium))
                Text(detail)
                    .font(DarkbloomTheme.chivo(11))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking or updating status")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MenuBarNavigationLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 4)
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
        }
    }
}

struct MenuBarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DarkbloomTheme.chivo(12, weight: .medium))
            .foregroundStyle(prominent ? Color.white : StudioPalette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                prominent ? StudioPalette.cobalt : StudioPalette.surface,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(StudioPalette.line, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.42)
    }
}

struct MenuBarSampleBadge: View {
    var body: some View {
        Text("PREVIEW")
            .font(DarkbloomTheme.chivo(8.5, weight: .medium))
            .tracking(0.7)
            .foregroundStyle(StudioPalette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(StudioPalette.accentSoft, in: Capsule())
    }
}
