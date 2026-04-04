/// DesignSystem — Warm, hand-drawn aesthetic tokens for EigenInference.
///
/// Provides a unified color palette, typography helpers, and reusable
/// view modifiers that match the landing page's hand-drawn style:
/// cream backgrounds, coral/teal/gold accents, sketchy borders.

import SwiftUI

// MARK: - Color Palette

extension Color {
    // Backgrounds
    static let warmBg         = Color(red: 1.0, green: 0.973, blue: 0.906)   // #FFF8E7
    static let warmBgSecondary = Color(red: 1.0, green: 0.953, blue: 0.831)  // #FFF3D4
    static let warmBgTertiary = Color(red: 1.0, green: 0.929, blue: 0.835)   // #FFEDD5
    static let warmBgElevated = Color(red: 1.0, green: 0.894, blue: 0.741)   // #FFE4BD

    // Ink / text
    static let warmInk        = Color(red: 0.231, green: 0.173, blue: 0.208) // #3B2C35
    static let warmInkLight   = Color(red: 0.420, green: 0.357, blue: 0.396) // #6B5B65
    static let warmInkFaint   = Color(red: 0.608, green: 0.545, blue: 0.584) // #9B8B95

    // Accents
    static let coral          = Color(red: 0.957, green: 0.518, blue: 0.373) // #F4845F
    static let coralLight     = Color(red: 0.984, green: 0.741, blue: 0.643) // #FBBDA4
    static let tealAccent     = Color(red: 0.176, green: 0.620, blue: 0.478) // #2D9E7A
    static let tealLight      = Color(red: 0.659, green: 0.902, blue: 0.812) // #A8E6CF
    static let tealDark       = Color(red: 0.106, green: 0.420, blue: 0.314) // #1B6B50
    static let gold           = Color(red: 0.910, green: 0.659, blue: 0.220) // #E8A838
    static let goldLight      = Color(red: 1.0, green: 0.878, blue: 0.627)   // #FFE0A0
    static let blueAccent     = Color(red: 0.357, green: 0.553, blue: 0.937) // #5B8DEF
    static let blueLight      = Color(red: 0.741, green: 0.831, blue: 1.0)   // #BDD4FF
    static let purpleAccent   = Color(red: 0.608, green: 0.447, blue: 0.812) // #9B72CF
    static let purpleLight    = Color(red: 0.847, green: 0.773, blue: 0.941) // #D8C5F0

    // Semantic (status)
    static let warmSuccess    = Color.tealAccent
    static let warmWarning    = Color.gold
    static let warmError      = Color(red: 0.878, green: 0.353, blue: 0.200) // #E05A33
    static let warmInfo       = Color.blueAccent
}

// MARK: - ShapeStyle convenience (so .foregroundStyle(.warmInk) compiles)

extension ShapeStyle where Self == Color {
    static var warmBg: Color { Color.warmBg }
    static var warmBgSecondary: Color { Color.warmBgSecondary }
    static var warmBgTertiary: Color { Color.warmBgTertiary }
    static var warmBgElevated: Color { Color.warmBgElevated }
    static var warmInk: Color { Color.warmInk }
    static var warmInkLight: Color { Color.warmInkLight }
    static var warmInkFaint: Color { Color.warmInkFaint }
    static var coral: Color { Color.coral }
    static var coralLight: Color { Color.coralLight }
    static var tealAccent: Color { Color.tealAccent }
    static var tealLight: Color { Color.tealLight }
    static var tealDark: Color { Color.tealDark }
    static var gold: Color { Color.gold }
    static var goldLight: Color { Color.goldLight }
    static var blueAccent: Color { Color.blueAccent }
    static var blueLight: Color { Color.blueLight }
    static var purpleAccent: Color { Color.purpleAccent }
    static var purpleLight: Color { Color.purpleLight }
    static var warmSuccess: Color { Color.warmSuccess }
    static var warmWarning: Color { Color.warmWarning }
    static var warmError: Color { Color.warmError }
    static var warmInfo: Color { Color.warmInfo }
}

// MARK: - Typography

/// Display font for headings — uses SF Rounded for a friendlier feel.
/// If Caveat is bundled, swap to `.custom("Caveat", size:)`.
extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let displayLarge  = Font.display(28)
    static let displayMedium = Font.display(22)
    static let displaySmall  = Font.display(18)

    static let bodyWarm      = Font.system(size: 13, weight: .medium, design: .rounded)
    static let captionWarm   = Font.system(size: 11, weight: .medium, design: .rounded)
    static let monoWarm      = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: - Warm Card Modifier

struct WarmCardModifier: ViewModifier {
    var padding: CGFloat
    var borderColor: Color
    var hasShadow: Bool

    init(padding: CGFloat = 14, borderColor: Color = .warmInk.opacity(0.12), hasShadow: Bool = true) {
        self.padding = padding
        self.borderColor = borderColor
        self.hasShadow = hasShadow
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.warmBgSecondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
            .shadow(
                color: hasShadow ? .warmInk.opacity(0.06) : .clear,
                radius: 1, x: 2, y: 2
            )
    }
}

extension View {
    func warmCard(padding: CGFloat = 14, border: Color = .warmInk.opacity(0.12)) -> some View {
        modifier(WarmCardModifier(padding: padding, borderColor: border))
    }

    func warmCardAccent(_ accent: Color, padding: CGFloat = 14) -> some View {
        modifier(WarmCardModifier(padding: padding, borderColor: accent.opacity(0.3)))
    }
}

// MARK: - Warm Status Badge

struct WarmBadge: View {
    let text: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1.5))
    }
}

// MARK: - Warm Button Style

struct WarmButtonStyle: ButtonStyle {
    var color: Color
    var filled: Bool

    init(_ color: Color = .coral, filled: Bool = true) {
        self.color = color
        self.filled = filled
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(filled ? .white : color)
            .background(filled ? color : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(filled ? color : color.opacity(0.4), lineWidth: 2)
            )
            .shadow(
                color: configuration.isPressed ? .clear : .warmInk.opacity(0.08),
                radius: 0, x: configuration.isPressed ? 0 : 2, y: configuration.isPressed ? 0 : 2
            )
            .offset(
                x: configuration.isPressed ? 1 : 0,
                y: configuration.isPressed ? 1 : 0
            )
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Stat Card

struct WarmStatCard: View {
    let icon: String
    let label: String
    let value: String
    var detail: String? = nil
    var iconColor: Color = .coral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Text(label)
                    .font(.captionWarm)
                    .foregroundStyle(Color.warmInkLight)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.warmInk)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.warmInkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .warmCard(padding: 12)
    }
}

// MARK: - Warm Section Header

struct WarmSectionHeader: View {
    let title: String
    var icon: String? = nil
    var color: Color = .warmInk

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color.opacity(0.6))
            }
            Text(title)
                .font(.displaySmall)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Pointer Cursor on Hover

struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointerOnHover() -> some View {
        modifier(PointerCursorModifier())
    }
}

// MARK: - Warm Background

struct WarmBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.warmBg)
    }
}

extension View {
    func warmBackground() -> some View {
        modifier(WarmBackground())
    }
}
