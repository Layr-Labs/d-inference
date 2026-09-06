import SwiftUI

struct MacDeviceArtwork: View {
    let identity: MachineIdentity
    @Binding var fieldFocus: CGFloat
    @Binding var fieldPointer: CGPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview
    @State private var isPresented = false
    @State private var pointerOffset = CGSize.zero
    @State private var isFlipped = false
    @State private var isCardHovered = false

    private var motionIsReduced: Bool {
        reduceMotion || isCapturingPreview
    }

    var body: some View {
        GeometryReader { geometry in
            deviceCard(in: geometry.size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    updatePointer(for: phase, in: geometry.size)
                }
        }
        .onAppear {
            isPresented = true
            #if DEBUG
            if ProcessInfo.processInfo.environment["DARKBLOOM_PREVIEW_CARD_BACK"] == "1" {
                isFlipped = true
            }
            #endif
            updateFieldFocus()
        }
        .onDisappear {
            fieldFocus = 0
            fieldPointer = CGPoint(x: 0.66, y: 0.5)
        }
        .onChange(of: isFlipped) { _, _ in
            updateFieldFocus()
        }
        .onChange(of: reduceMotion) { _, shouldReduceMotion in
            if shouldReduceMotion {
                pointerOffset = .zero
                fieldPointer = CGPoint(x: 0.66, y: 0.5)
                isPresented = true
            }
        }
    }

    private func deviceCard(in size: CGSize) -> some View {
        let horizontalAnchor = max(12, min(34, size.width * 0.07))

        return MachineCardView(identity: identity, isFlipped: $isFlipped)
            .onHover { isHovering in
                isCardHovered = isHovering
                updateFieldFocus()
            }
            .opacity(isPresented ? 1 : 0)
            .scaleEffect(
                isPresented
                    ? ((isCardHovered || isFlipped) && !motionIsReduced ? 1.012 : 1)
                    : 0.955
            )
            .offset(
                x: horizontalAnchor + (motionIsReduced ? 0 : pointerOffset.width),
                y: -6 + (motionIsReduced ? 0 : pointerOffset.height)
            )
            .rotation3DEffect(
                .degrees(motionIsReduced ? 0 : Double(-pointerOffset.height) * 0.6),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.65
            )
            .rotation3DEffect(
                .degrees(motionIsReduced ? 0 : Double(pointerOffset.width) * 0.6),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.65
            )
            .animation(
                motionIsReduced
                    ? nil
                    : .spring(response: 0.72, dampingFraction: 0.82).delay(0.14),
                value: isPresented
            )
            .animation(
                motionIsReduced ? nil : .easeOut(duration: 0.16),
                value: pointerOffset
            )
            .animation(
                motionIsReduced ? nil : .spring(response: 0.78, dampingFraction: 0.84),
                value: isFlipped
            )
            .animation(
                motionIsReduced ? nil : .easeOut(duration: 0.2),
                value: isCardHovered
            )
    }

    private func updatePointer(
        for phase: HoverPhase,
        in size: CGSize
    ) {
        guard !motionIsReduced else {
            pointerOffset = .zero
            fieldPointer = CGPoint(x: 0.66, y: 0.5)
            return
        }

        switch phase {
        case let .active(location):
            let horizontal = ((location.x / max(size.width, 1)) - 0.5) * 2
            let vertical = ((location.y / max(size.height, 1)) - 0.5) * 2
            pointerOffset = CGSize(width: horizontal * 4, height: vertical * 4)
            fieldPointer = CGPoint(
                x: 0.66 + horizontal * 0.018,
                y: 0.5 + vertical * 0.022
            )
        case .ended:
            pointerOffset = .zero
            fieldPointer = CGPoint(x: 0.66, y: 0.5)
        }
    }

    private func updateFieldFocus() {
        let newFocus: CGFloat
        if isFlipped {
            newFocus = 0.58
        } else if isCardHovered {
            newFocus = 0.22
        } else {
            newFocus = 0
        }

        withAnimation(
            motionIsReduced ? nil : .easeInOut(duration: 0.42)
        ) {
            fieldFocus = newFocus
        }
    }
}
