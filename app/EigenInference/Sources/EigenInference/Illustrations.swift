/// Illustrations — Hand-drawn SwiftUI illustrations for Darkbloom.
///
/// Cartoon Mac character with mood-based expressions, plus decorative
/// elements for onboarding, empty states, and dashboards.
/// All resolution-independent — built from SwiftUI Shapes and Paths.

import SwiftUI

// MARK: - Cartoon Mac Character

/// A cute Mac laptop character with face and expressions.
struct CartoonMac: View {
    var mood: AvatarMood = .greeting
    var size: CGFloat = 64

    private var scale: CGFloat { size / 64 }

    var body: some View {
        ZStack {
            // Shadow
            Ellipse()
                .fill(Color.adaptiveInk.opacity(0.06))
                .frame(width: 48 * scale, height: 8 * scale)
                .offset(y: 28 * scale)

            // Mac body
            macBody
                .offset(y: -4 * scale)
        }
        .frame(width: size, height: size)
    }

    private var macBody: some View {
        ZStack {
            // Screen (main body)
            RoundedRectangle(cornerRadius: 6 * scale)
                .fill(Color.adaptiveBgSecondary)
                .frame(width: 48 * scale, height: 36 * scale)
                .overlay(
                    RoundedRectangle(cornerRadius: 6 * scale)
                        .strokeBorder(Color.adaptiveInk, lineWidth: 2.5 * scale)
                )
                .offset(y: -6 * scale)

            // Screen inner (colored based on mood)
            RoundedRectangle(cornerRadius: 3 * scale)
                .fill(mood.color.opacity(0.15))
                .frame(width: 40 * scale, height: 26 * scale)
                .overlay(
                    RoundedRectangle(cornerRadius: 3 * scale)
                        .strokeBorder(mood.color.opacity(0.3), lineWidth: 1 * scale)
                )
                .offset(y: -8 * scale)

            // Face on screen
            face
                .offset(y: -8 * scale)

            // Stand/chin
            Path { path in
                let w = 48 * scale
                let chinY = 12 * scale
                path.move(to: CGPoint(x: (size - w) / 2 + 14 * scale, y: chinY))
                path.addQuadCurve(
                    to: CGPoint(x: (size - w) / 2 + w - 14 * scale, y: chinY),
                    control: CGPoint(x: size / 2, y: chinY + 7 * scale)
                )
            }
            .stroke(Color.adaptiveInk, lineWidth: 2 * scale)

            // Base
            RoundedRectangle(cornerRadius: 2 * scale)
                .fill(Color.adaptiveBgElevated)
                .frame(width: 30 * scale, height: 4 * scale)
                .overlay(
                    RoundedRectangle(cornerRadius: 2 * scale)
                        .strokeBorder(Color.adaptiveInk, lineWidth: 1.5 * scale)
                )
                .offset(y: 18 * scale)

            // Status light (on chin area)
            Circle()
                .fill(mood.color)
                .frame(width: 3 * scale, height: 3 * scale)
                .shadow(color: mood.color.opacity(0.6), radius: 3 * scale)
                .offset(y: 12 * scale)
        }
    }

    @ViewBuilder
    private var face: some View {
        switch mood {
        case .greeting:
            // Happy face with open eyes
            HStack(spacing: 8 * scale) {
                eye(open: true)
                eye(open: true)
            }
            .offset(y: -3 * scale)
            // Smile
            smile(wide: false)
                .offset(y: 4 * scale)

        case .explaining:
            // Neutral face
            HStack(spacing: 8 * scale) {
                eye(open: true)
                eye(open: true)
            }
            .offset(y: -3 * scale)
            // Small mouth
            RoundedRectangle(cornerRadius: 1 * scale)
                .fill(Color.adaptiveInk)
                .frame(width: 6 * scale, height: 2 * scale)
                .offset(y: 4 * scale)

        case .excited:
            // Big happy eyes
            HStack(spacing: 8 * scale) {
                starEye
                starEye
            }
            .offset(y: -3 * scale)
            // Big smile
            smile(wide: true)
                .offset(y: 4 * scale)

        case .thinking:
            // Looking up eyes
            HStack(spacing: 8 * scale) {
                eye(open: true, lookUp: true)
                eye(open: true, lookUp: true)
            }
            .offset(y: -4 * scale)
            // Wavy mouth
            wavyMouth
                .offset(y: 3 * scale)

        case .concerned:
            // Worried eyes
            HStack(spacing: 8 * scale) {
                eye(open: true)
                eye(open: true)
            }
            .offset(y: -3 * scale)
            // Frown
            frown
                .offset(y: 5 * scale)

        case .celebrating:
            // Closed happy eyes (^_^)
            HStack(spacing: 8 * scale) {
                closedHappyEye
                closedHappyEye
            }
            .offset(y: -2 * scale)
            // Big smile
            smile(wide: true)
                .offset(y: 4 * scale)
        }
    }

    // MARK: - Face Parts

    private func eye(open: Bool, lookUp: Bool = false) -> some View {
        ZStack {
            if open {
                Circle()
                    .fill(Color.adaptiveInk)
                    .frame(width: 5 * scale, height: 5 * scale)
                // Shine
                Circle()
                    .fill(Color.white)
                    .frame(width: 1.5 * scale, height: 1.5 * scale)
                    .offset(x: 1 * scale, y: lookUp ? -2 * scale : -1 * scale)
            }
        }
    }

    private var starEye: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 5 * scale, weight: .bold))
            .foregroundStyle(Color.adaptiveGold)
    }

    private var closedHappyEye: some View {
        Path { path in
            let w = 5 * scale
            path.move(to: CGPoint(x: -w/2, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: w/2, y: 0),
                control: CGPoint(x: 0, y: -3 * scale)
            )
        }
        .stroke(Color.adaptiveInk, lineWidth: 1.5 * scale)
        .frame(width: 5 * scale, height: 4 * scale)
    }

    private func smile(wide: Bool) -> some View {
        Path { path in
            let w = (wide ? 12 : 8) * scale
            path.move(to: CGPoint(x: -w/2, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: w/2, y: 0),
                control: CGPoint(x: 0, y: 4 * scale)
            )
        }
        .stroke(Color.adaptiveInk, lineWidth: 1.5 * scale)
        .frame(width: 14 * scale, height: 6 * scale)
    }

    private var frown: some View {
        Path { path in
            let w = 8 * scale
            path.move(to: CGPoint(x: -w/2, y: 2 * scale))
            path.addQuadCurve(
                to: CGPoint(x: w/2, y: 2 * scale),
                control: CGPoint(x: 0, y: -2 * scale)
            )
        }
        .stroke(Color.adaptiveInk, lineWidth: 1.5 * scale)
        .frame(width: 10 * scale, height: 5 * scale)
    }

    private var wavyMouth: some View {
        Path { path in
            let w = 8 * scale
            path.move(to: CGPoint(x: -w/2, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: -w/4, y: -2 * scale))
            path.addQuadCurve(to: CGPoint(x: w/2, y: 0), control: CGPoint(x: w/4, y: 2 * scale))
        }
        .stroke(Color.adaptiveInk, lineWidth: 1.5 * scale)
        .frame(width: 10 * scale, height: 6 * scale)
    }
}

// MARK: - Decorative Sparkles

struct Sparkles: View {
    var color: Color = .gold
    var count: Int = 3

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                SparkleShape()
                    .fill(color.opacity(Double.random(in: 0.4...0.8)))
                    .frame(width: CGFloat.random(in: 6...12), height: CGFloat.random(in: 6...12))
                    .offset(
                        x: CGFloat.random(in: -20...20),
                        y: CGFloat.random(in: -20...20)
                    )
                    .rotationEffect(.degrees(Double.random(in: 0...45)))
            }
        }
    }
}

struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addLine(to: CGPoint(x: cx + r * 0.3, y: cy - r * 0.3))
        path.addLine(to: CGPoint(x: cx + r, y: cy))
        path.addLine(to: CGPoint(x: cx + r * 0.3, y: cy + r * 0.3))
        path.addLine(to: CGPoint(x: cx, y: cy + r))
        path.addLine(to: CGPoint(x: cx - r * 0.3, y: cy + r * 0.3))
        path.addLine(to: CGPoint(x: cx - r, y: cy))
        path.addLine(to: CGPoint(x: cx - r * 0.3, y: cy - r * 0.3))
        path.closeSubpath()
        return path
    }
}

// MARK: - Shield Illustration

struct ShieldIllustration: View {
    var passed: Bool = true
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            // Shield shape
            Image(systemName: passed ? "shield.checkered" : "shield.slash")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(passed ? Color.adaptiveTealAccent : Color.adaptiveError)
                .shadow(color: (passed ? Color.adaptiveTealAccent : Color.adaptiveError).opacity(0.3), radius: 6)

            if passed {
                // Sparkles around shield
                Sparkles(color: .tealAccent, count: 4)
                    .frame(width: size * 1.5, height: size * 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Coin Stack Illustration

struct CoinStackIllustration: View {
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            // Stack of coins
            ForEach(0..<3, id: \.self) { i in
                Ellipse()
                    .fill(Color.adaptiveGold)
                    .frame(width: size * 0.5, height: size * 0.2)
                    .overlay(
                        Ellipse()
                            .strokeBorder(Color.adaptiveInk, lineWidth: 1.5)
                    )
                    .offset(y: CGFloat(2 - i) * size * 0.12)
            }

            // Dollar sign on top coin
            Text("$")
                .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                .foregroundStyle(Color.adaptiveInk)
                .offset(y: -size * 0.05)

            // Sparkles
            Sparkles(color: .gold, count: 3)
                .frame(width: size, height: size)
                .offset(x: size * 0.3, y: -size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Network Illustration (3 connected Macs)

struct NetworkIllustration: View {
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            // Connection lines
            Path { path in
                path.move(to: CGPoint(x: size * 0.5, y: size * 0.3))
                path.addLine(to: CGPoint(x: size * 0.2, y: size * 0.7))
                path.move(to: CGPoint(x: size * 0.5, y: size * 0.3))
                path.addLine(to: CGPoint(x: size * 0.8, y: size * 0.7))
            }
            .stroke(Color.adaptiveInk.opacity(0.2), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))

            // Center Mac (coordinator)
            CartoonMac(mood: .excited, size: size * 0.4)
                .offset(y: -size * 0.2)

            // Left Mac
            CartoonMac(mood: .greeting, size: size * 0.3)
                .offset(x: -size * 0.3, y: size * 0.2)

            // Right Mac
            CartoonMac(mood: .explaining, size: size * 0.3)
                .offset(x: size * 0.3, y: size * 0.2)

            // Lock icons on connections
            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.08, weight: .bold))
                .foregroundStyle(Color.adaptiveTealAccent)
                .offset(x: -size * 0.18, y: size * 0.02)

            Image(systemName: "lock.fill")
                .font(.system(size: size * 0.08, weight: .bold))
                .foregroundStyle(Color.adaptiveTealAccent)
                .offset(x: size * 0.18, y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}
