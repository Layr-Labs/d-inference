import SwiftUI

struct MachineCardView: View {
    let identity: MachineIdentity
    @Binding var isFlipped: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var flipAngle: Double {
        isFlipped ? 180 : 0
    }

    var body: some View {
        Button {
            withAnimation(
                reduceMotion
                    ? nil
                    : .spring(response: 0.72, dampingFraction: 0.82)
            ) {
                isFlipped.toggle()
            }
        } label: {
            ZStack {
                MachineCardFront(identity: identity)
                    .modifier(FlipFaceModifier(angle: flipAngle))

                MachineCardDetailsView(identity: identity)
                    .modifier(FlipFaceModifier(angle: flipAngle - 180))
            }
            .frame(width: 300, height: 322)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isFlipped ? "Return to device view" : "Inspect this Mac")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFlipped ? "Machine details" : "This Mac")
        .accessibilityValue(
            isFlipped
                ? "\(identity.chipName), \(MachineFactsFormatter.memory(identity.physicalMemoryBytes)) memory"
                : "\(identity.displayName), \(identity.chipName)"
        )
        .accessibilityHint(isFlipped ? "Activate to return to the device" : "Activate to show hardware details")
    }
}

private struct MachineCardFront: View {
    let identity: MachineIdentity

    var body: some View {
        VStack(spacing: 13) {
            deviceGlyph
                .frame(width: 210, height: 138)
                .contentTransition(.symbolEffect(.replace))

            VStack(spacing: 5) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(DarkbloomTheme.accent)
                        .frame(width: 7, height: 7)
                    Text(identity.isDetected ? "THIS MAC" : "DETECTING")
                        .font(DarkbloomTheme.chivo(10, weight: .medium))
                        .tracking(1.1)
                }
                Text(identity.displayName)
                    .font(DarkbloomTheme.chivo(18))
                Text(identity.chipName)
                    .font(DarkbloomTheme.chivo(13))
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.56))
            }
            .contentTransition(.opacity)

            Label("Inspect this Mac", systemImage: "arrow.triangle.2.circlepath")
                .font(DarkbloomTheme.chivo(10, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))
        }
        .machineCardSurface()
    }

    @ViewBuilder
    private var deviceGlyph: some View {
        switch identity.formFactor {
        case .macMini:
            MacDesktopGlyph(style: .mini)
        case .macStudio:
            MacDesktopGlyph(style: .studio)
        default:
            Image(systemName: identity.formFactor.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 142, weight: .ultraLight))
                .foregroundStyle(DarkbloomTheme.ink)
        }
    }
}

private struct FlipFaceModifier: @MainActor AnimatableModifier {
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func body(content: Content) -> some View {
        content
            .opacity(cos(angle * .pi / 180) >= 0 ? 1 : 0)
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.58
            )
    }
}

struct MachineCardSurfaceModifier: ViewModifier {
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 21)
            .frame(width: 300, height: 322, alignment: alignment)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(.white.opacity(0.53))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.88), lineWidth: 1)
                    }
            }
            .shadow(color: DarkbloomTheme.accent.opacity(0.12), radius: 34, y: 20)
            .shadow(color: .black.opacity(0.045), radius: 18, y: 10)
    }
}

extension View {
    func machineCardSurface(alignment: Alignment = .center) -> some View {
        modifier(MachineCardSurfaceModifier(alignment: alignment))
    }
}
