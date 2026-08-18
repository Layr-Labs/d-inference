import SwiftUI

struct LocalAPILoopbackFilament: View {
    let mode: LocalAPIMode?
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isCapturingDarkbloomPreview) private var isCapturingPreview
    @State private var drawProgress: CGFloat = 0
    @State private var opacity = 0.35

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [
                    DarkbloomTheme.nodePale.opacity(0.34),
                    DarkbloomTheme.accent.opacity(0.05),
                    Color.clear,
                ],
                center: .center,
                startRadius: 4,
                endRadius: 120
            )

            LoopbackPath()
                .trim(from: 0, to: drawProgress)
                .stroke(
                    LinearGradient(
                        colors: [
                            DarkbloomTheme.nodePale,
                            DarkbloomTheme.accent,
                            DarkbloomTheme.nodePale,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )

            if mode == .unified {
                NetworkBranchPath()
                    .trim(from: 0, to: drawProgress)
                    .stroke(
                        DarkbloomTheme.accent.opacity(0.62),
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [4, 5])
                    )
            }

            Circle()
                .fill(isActive ? DarkbloomTheme.accent : Color.secondary.opacity(0.55))
                .frame(width: 8, height: 8)
                .offset(x: -92)

            Image(systemName: "desktopcomputer")
                .font(.system(size: 31, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? DarkbloomTheme.accent : Color.secondary)
                .frame(width: 66, height: 58)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(DarkbloomTheme.accent.opacity(isActive ? 0.22 : 0.10), lineWidth: 1)
                }

            if mode == .unified {
                Image(systemName: "network")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DarkbloomTheme.accent)
                    .offset(x: 96, y: -49)
            }
        }
        .frame(width: 230, height: 156)
        .opacity(opacity)
        .accessibilityHidden(true)
        .task(id: animationIdentity) {
            drawProgress = 0
            opacity = reduceMotion || isCapturingPreview ? 1 : 0.35

            guard isActive else {
                drawProgress = 1
                opacity = 0.65
                return
            }

            if reduceMotion || isCapturingPreview {
                drawProgress = 1
                opacity = 1
            } else {
                withAnimation(.easeOut(duration: 0.65)) {
                    drawProgress = 1
                    opacity = 1
                }
            }
        }
    }

    private var animationIdentity: AnimationIdentity {
        AnimationIdentity(
            isActive: isActive,
            reduceMotion: reduceMotion,
            isCapturingPreview: isCapturingPreview
        )
    }
}

private struct AnimationIdentity: Hashable {
    let isActive: Bool
    let reduceMotion: Bool
    let isCapturingPreview: Bool
}

private struct LoopbackPath: Shape {
    func path(in rect: CGRect) -> Path {
        let left = CGPoint(x: rect.minX + 20, y: rect.midY)
        let top = CGPoint(x: rect.midX, y: rect.minY + 22)
        let right = CGPoint(x: rect.maxX - 20, y: rect.midY)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY - 22)

        var path = Path()
        path.move(to: left)
        path.addCurve(
            to: top,
            control1: CGPoint(x: rect.minX + 42, y: rect.minY + 35),
            control2: CGPoint(x: rect.midX - 42, y: rect.minY + 22)
        )
        path.addCurve(
            to: right,
            control1: CGPoint(x: rect.midX + 42, y: rect.minY + 22),
            control2: CGPoint(x: rect.maxX - 42, y: rect.minY + 35)
        )
        path.addCurve(
            to: bottom,
            control1: CGPoint(x: rect.maxX - 42, y: rect.maxY - 35),
            control2: CGPoint(x: rect.midX + 42, y: rect.maxY - 22)
        )
        path.addCurve(
            to: left,
            control1: CGPoint(x: rect.midX - 42, y: rect.maxY - 22),
            control2: CGPoint(x: rect.minX + 42, y: rect.maxY - 35)
        )
        return path
    }
}

private struct NetworkBranchPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX + 34, y: rect.midY - 31))
        path.addCurve(
            to: CGPoint(x: rect.maxX - 17, y: rect.minY + 30),
            control1: CGPoint(x: rect.midX + 62, y: rect.midY - 34),
            control2: CGPoint(x: rect.maxX - 49, y: rect.minY + 30)
        )
        return path
    }
}
