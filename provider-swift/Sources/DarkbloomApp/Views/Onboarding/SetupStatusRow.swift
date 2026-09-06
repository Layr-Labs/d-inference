import SwiftUI

struct SetupStatusRow: View {
    let title: String
    let detail: String
    let state: SetupItemState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 13) {
            statusMark
                .frame(width: 19, height: 19)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DarkbloomTheme.chivo(13, weight: .medium))
                    .foregroundStyle(DarkbloomTheme.ink.opacity(state == .waiting ? 0.42 : 0.88))
                Text(detail)
                    .font(DarkbloomTheme.chivo(11))
                    .foregroundStyle(DarkbloomTheme.ink.opacity(state == .waiting ? 0.3 : 0.46))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 42)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    @ViewBuilder
    private var statusMark: some View {
        switch state {
        case .waiting:
            Circle()
                .stroke(DarkbloomTheme.ink.opacity(0.14), lineWidth: 1)
                .overlay {
                    Circle()
                        .fill(DarkbloomTheme.ink.opacity(0.12))
                        .frame(width: 4, height: 4)
                }
        case .working:
            BreathingStatusDot()
        case .complete:
            Circle()
                .fill(DarkbloomTheme.accent)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
                .transition(.scale.combined(with: .opacity))
        case .issue:
            Circle()
                .fill(Color.orange.opacity(0.16))
                .overlay {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.orange)
                }
        case .advisory:
            Circle()
                .fill(DarkbloomTheme.accent.opacity(0.12))
                .overlay {
                    Image(systemName: "info")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DarkbloomTheme.accent)
                }
        }
    }

    private var accessibilityState: String {
        switch state {
        case .waiting: "Waiting"
        case .working: "In progress"
        case .complete: "Complete"
        case .advisory: "Advisory"
        case .issue: "Needs attention"
        }
    }
}

struct BreathingStatusDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview
    @State private var isExpanded = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DarkbloomTheme.accent.opacity(0.16))
                .scaleEffect(isExpanded ? 1 : 0.55)
            Circle()
                .fill(DarkbloomTheme.accent)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            guard !reduceMotion, !isCapturingPreview else {
                isExpanded = true
                return
            }
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                isExpanded = true
            }
        }
    }
}
