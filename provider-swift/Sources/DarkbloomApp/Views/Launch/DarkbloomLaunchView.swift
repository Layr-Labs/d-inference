import SwiftUI

struct DarkbloomLaunchView: View {
    let mode: DarkbloomLaunchMode
    let onRevealApp: () -> Void
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blueBloomIsOpen = false
    @State private var whiteBloomIsOpen = false
    @State private var whiteCanvasIsVisible = false
    @State private var wordmarkIsVisible = false
    @State private var isDissolving = false
    @State private var hasStarted = false

    var body: some View {
        GeometryReader { geometry in
            let shortSide = min(geometry.size.width, geometry.size.height)

            ZStack {
                ZStack {
                    Color(red: 0.012, green: 0.015, blue: 0.024)

                    SpatialFieldView()
                        .frame(width: shortSide * 0.43, height: shortSide * 0.43)
                        .clipShape(Circle())
                        .scaleEffect(blueBloomIsOpen ? 3.45 : 0.025)
                        .blur(radius: blueBloomIsOpen ? 0 : 18)
                        .shadow(color: DarkbloomTheme.accent.opacity(0.72), radius: 54)

                    Circle()
                        .fill(.white)
                        .frame(width: shortSide * 0.34, height: shortSide * 0.34)
                        .scaleEffect(whiteBloomIsOpen ? 5.9 : 0.01)
                        .blur(radius: whiteBloomIsOpen ? 0 : 12)
                        .shadow(color: .white.opacity(0.9), radius: whiteBloomIsOpen ? 26 : 8)

                    Circle()
                        .fill(DarkbloomTheme.accent)
                        .frame(width: 10, height: 10)
                        .scaleEffect(blueBloomIsOpen ? 0.2 : 1)
                        .opacity(blueBloomIsOpen ? 0 : 1)
                        .shadow(color: DarkbloomTheme.accent, radius: 18)
                }
                .opacity(isDissolving ? 0 : 1)

                Color.white
                    .opacity(whiteCanvasIsVisible && !isDissolving ? 1 : 0)

                Text("Darkbloom")
                    .font(DarkbloomTheme.chivo(28))
                    .tracking(-0.9)
                    .foregroundStyle(DarkbloomTheme.ink)
                    .opacity(wordmarkIsVisible && !isDissolving ? 1 : 0)
                    .scaleEffect(wordmarkIsVisible ? 1 : 0.975)
                    .blur(radius: wordmarkIsVisible ? 0 : 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task {
            guard !hasStarted else {
                return
            }
            hasStarted = true

            if reduceMotion {
                onRevealApp()
                onFinished()
                return
            }

            let timingScale = mode == .full ? 1.0 : 0.42

            try? await Task.sleep(for: .seconds(0.12 * timingScale))
            withAnimation(.spring(response: 0.62 * timingScale, dampingFraction: 0.8)) {
                blueBloomIsOpen = true
            }

            try? await Task.sleep(for: .seconds(0.44 * timingScale))
            withAnimation(.easeInOut(duration: 0.58 * timingScale)) {
                whiteBloomIsOpen = true
            }

            try? await Task.sleep(for: .seconds(0.36 * timingScale))
            withAnimation(.easeInOut(duration: 0.2 * timingScale)) {
                whiteCanvasIsVisible = true
            }
            withAnimation(.easeOut(duration: 0.28 * timingScale).delay(0.04 * timingScale)) {
                wordmarkIsVisible = true
            }

            try? await Task.sleep(for: .seconds(0.36 * timingScale))
            onRevealApp()

            try? await Task.sleep(for: .seconds(0.08 * timingScale))
            withAnimation(.easeInOut(duration: 0.38 * timingScale)) {
                isDissolving = true
            }

            try? await Task.sleep(for: .seconds(0.4 * timingScale))
            onFinished()
        }
    }
}

enum DarkbloomLaunchMode {
    case full
    case ignition
}
