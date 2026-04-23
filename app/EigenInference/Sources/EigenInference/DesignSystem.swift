/// DesignSystem — Darkbloom design tokens matching console.darkbloom.dev.
///
/// Light and dark mode palettes sourced from the EigenCloud Brand Book
/// via console-ui/src/app/globals.css. Provides unified colors, typography,
/// and reusable view modifiers.

import SwiftUI

// MARK: - Color Palette

extension Color {
    // Light mode backgrounds
    static let bgPrimary     = Color(red: 0.953, green: 0.953, blue: 0.953) // #F2F2F2
    static let bgSecondary   = Color(red: 0.910, green: 0.910, blue: 0.910) // #E8E8E8
    static let bgTertiary    = Color(red: 0.871, green: 0.871, blue: 0.871) // #DEDEDE
    static let bgElevated    = Color(red: 0.847, green: 0.863, blue: 0.898) // #D8DCE5
    static let bgHover       = Color(red: 0.878, green: 0.878, blue: 0.894) // #E0E0E4
    static let bgWhite       = Color.white                                          // #FFFFFF

    // Light mode ink / text
    static let inkPrimary    = Color(red: 0.000, green: 0.000, blue: 0.000) // #000000
    static let inkLight      = Color(red: 0.400, green: 0.435, blue: 0.486) // #666F7C
    static let inkFaint      = Color(red: 0.675, green: 0.694, blue: 0.737) // #ACB1BC

    // Light mode borders
    static let borderDim     = Color(red: 0.847, green: 0.863, blue: 0.898) // #D8DCE5
    static let borderSubtle  = Color(red: 0.675, green: 0.694, blue: 0.737) // #ACB1BC

    // Brand accents (light mode)
    static let brandAccent       = Color(red: 0.102, green: 0.047, blue: 0.427) // #1A0C6D
    static let brandAccentDim   = Color(red: 0.102, green: 0.047, blue: 0.427).opacity(0.06)
    static let brandAccentHover = Color(red: 0.075, green: 0.035, blue: 0.322) // #130952
    static let coral            = Color(red: 0.102, green: 0.047, blue: 0.427) // #1A0C6D (brand = coral slot)
    static let coralLight       = Color(red: 0.102, green: 0.047, blue: 0.427).opacity(0.06)
    static let tealAccent       = Color(red: 0.176, green: 0.620, blue: 0.478) // #2D9E7A
    static let tealLight        = Color(red: 0.820, green: 0.980, blue: 0.898) // #D1FAE5
    static let tealDark         = Color(red: 0.106, green: 0.420, blue: 0.314) // #1B6B50
    static let blueAccent       = Color(red: 0.584, green: 0.749, blue: 1.000) // #95BFFF
    static let blueLight        = Color(red: 0.859, green: 0.918, blue: 0.996) // #DBEAFE
    static let purpleAccent     = Color(red: 0.486, green: 0.227, blue: 0.929) // #7C3AED
    static let purpleLight      = Color(red: 0.867, green: 0.839, blue: 0.996) // #DDD6FE
    static let gold             = Color(red: 0.851, green: 0.467, blue: 0.024) // #D97706
    static let goldLight        = Color(red: 0.996, green: 0.953, blue: 0.780) // #FEF3C7

    // Semantic (status)
    static let warmSuccess = Color.tealAccent
    static let warmWarning = Color.gold
    static let warmError   = Color(red: 0.863, green: 0.149, blue: 0.149) // #DC2626
    static let warmInfo    = Color.blueAccent

    // Dark mode backgrounds
    static let darkBgPrimary   = Color(red: 0.059, green: 0.059, blue: 0.078) // #0F0F14
    static let darkBgSecondary = Color(red: 0.086, green: 0.086, blue: 0.122) // #16161F
    static let darkBgTertiary  = Color(red: 0.118, green: 0.118, blue: 0.165) // #1E1E2A
    static let darkBgElevated  = Color(red: 0.149, green: 0.149, blue: 0.212) // #262636
    static let darkBgHover     = Color(red: 0.165, green: 0.165, blue: 0.235) // #2A2A3C

    // Dark mode ink / text
    static let darkInkPrimary  = Color(red: 0.910, green: 0.910, blue: 0.925) // #E8E8EC
    static let darkInkLight    = Color(red: 0.612, green: 0.639, blue: 0.686) // #9CA3AF
    static let darkInkFaint    = Color(red: 0.420, green: 0.447, blue: 0.502) // #6B7280

    // Dark mode borders
    static let darkBorderDim    = Color(red: 0.149, green: 0.149, blue: 0.212) // #262636
    static let darkBorderSubtle = Color(red: 0.212, green: 0.212, blue: 0.282) // #363648

    // Dark mode brand accents
    static let darkBrandAccent      = Color(red: 0.506, green: 0.549, blue: 0.973) // #818CF8
    static let darkBrandAccentDim   = Color(red: 0.506, green: 0.549, blue: 0.973).opacity(0.10)
    static let darkBrandAccentHover = Color(red: 0.388, green: 0.400, blue: 0.945) // #6366F1
    static let darkCoral            = Color(red: 0.506, green: 0.549, blue: 0.973) // #818CF8
    static let darkCoralLight       = Color(red: 0.506, green: 0.549, blue: 0.973).opacity(0.10)
    static let darkTealAccent       = Color(red: 0.204, green: 0.827, blue: 0.600) // #34D399
    static let darkTealLight        = Color(red: 0.204, green: 0.827, blue: 0.600).opacity(0.12)
    static let darkTealDark         = Color(red: 0.431, green: 0.906, blue: 0.718) // #6EE7B7
    static let darkBlueAccent       = Color(red: 0.576, green: 0.773, blue: 0.992) // #93C5FD
    static let darkBlueLight        = Color(red: 0.576, green: 0.773, blue: 0.992).opacity(0.12)
    static let darkPurpleAccent     = Color(red: 0.655, green: 0.545, blue: 0.980) // #A78BFA
    static let darkPurpleLight      = Color(red: 0.655, green: 0.545, blue: 0.980).opacity(0.12)
    static let darkGold             = Color(red: 0.984, green: 0.749, blue: 0.141) // #FBBF24
    static let darkGoldLight        = Color(red: 0.984, green: 0.749, blue: 0.141).opacity(0.12)
    static let darkError            = Color(red: 0.973, green: 0.443, blue: 0.443) // #F87171
}

// MARK: - Adaptive Colors (respond to light/dark)

extension Color {
    static var adaptiveBgPrimary: Color {
        Color(light: .bgPrimary, dark: .darkBgPrimary)
    }
    static var adaptiveBgSecondary: Color {
        Color(light: .bgSecondary, dark: .darkBgSecondary)
    }
    static var adaptiveBgTertiary: Color {
        Color(light: .bgTertiary, dark: .darkBgTertiary)
    }
    static var adaptiveBgElevated: Color {
        Color(light: .bgElevated, dark: .darkBgElevated)
    }
    static var adaptiveBgHover: Color {
        Color(light: .bgHover, dark: .darkBgHover)
    }
    static var adaptiveBgWhite: Color {
        Color(light: .bgWhite, dark: .darkBgTertiary)
    }

    static var adaptiveInk: Color {
        Color(light: .inkPrimary, dark: .darkInkPrimary)
    }
    static var adaptiveInkLight: Color {
        Color(light: .inkLight, dark: .darkInkLight)
    }
    static var adaptiveInkFaint: Color {
        Color(light: .inkFaint, dark: .darkInkFaint)
    }

    static var adaptiveBorderDim: Color {
        Color(light: .borderDim, dark: .darkBorderDim)
    }
    static var adaptiveBorderSubtle: Color {
        Color(light: .borderSubtle, dark: .darkBorderSubtle)
    }

    static var adaptiveBrand: Color {
        Color(light: .brandAccent, dark: .darkBrandAccent)
    }
    static var adaptiveBrandDim: Color {
        Color(light: .brandAccentDim, dark: .darkBrandAccentDim)
    }
    static var adaptiveBrandHover: Color {
        Color(light: .brandAccentHover, dark: .darkBrandAccentHover)
    }

    static var adaptiveCoral: Color {
        Color(light: .coral, dark: .darkCoral)
    }
    static var adaptiveCoralLight: Color {
        Color(light: .coralLight, dark: .darkCoralLight)
    }
    static var adaptiveTealAccent: Color {
        Color(light: .tealAccent, dark: .darkTealAccent)
    }
    static var adaptiveTealLight: Color {
        Color(light: .tealLight, dark: .darkTealLight)
    }
    static var adaptiveTealDark: Color {
        Color(light: .tealDark, dark: .darkTealDark)
    }
    static var adaptiveBlueAccent: Color {
        Color(light: .blueAccent, dark: .darkBlueAccent)
    }
    static var adaptiveBlueLight: Color {
        Color(light: .blueLight, dark: .darkBlueLight)
    }
    static var adaptivePurpleAccent: Color {
        Color(light: .purpleAccent, dark: .darkPurpleAccent)
    }
    static var adaptivePurpleLight: Color {
        Color(light: .purpleLight, dark: .darkPurpleLight)
    }
    static var adaptiveGold: Color {
        Color(light: .gold, dark: .darkGold)
    }
    static var adaptiveGoldLight: Color {
        Color(light: .goldLight, dark: .darkGoldLight)
    }

    static var adaptiveError: Color {
        Color(light: .warmError, dark: .darkError)
    }
}

// MARK: - Adaptive Color Helper

/// Creates a Color that adapts to light/dark appearance using NSColor
/// with dynamic provider. This ensures the color updates live when the
/// system appearance changes.
extension Color {
    init(light: Color, dark: Color) {
        self.init(NSColor(name: nil, dynamicProvider: { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(dark)
            } else {
                return NSColor(light)
            }
        }))
    }
}

// MARK: - ShapeStyle convenience

extension ShapeStyle where Self == Color {
    static var bgPrimary: Color { Color.bgPrimary }
    static var bgSecondary: Color { Color.bgSecondary }
    static var bgTertiary: Color { Color.bgTertiary }
    static var bgElevated: Color { Color.bgElevated }
    static var bgHover: Color { Color.bgHover }
    static var bgWhite: Color { Color.bgWhite }
    static var inkPrimary: Color { Color.inkPrimary }
    static var inkLight: Color { Color.inkLight }
    static var inkFaint: Color { Color.inkFaint }
    static var borderDim: Color { Color.borderDim }
    static var borderSubtle: Color { Color.borderSubtle }
    static var brandAccent: Color { Color.brandAccent }
    static var coral: Color { Color.coral }
    static var coralLight: Color { Color.coralLight }
    static var tealAccent: Color { Color.tealAccent }
    static var tealLight: Color { Color.tealLight }
    static var tealDark: Color { Color.tealDark }
    static var blueAccent: Color { Color.blueAccent }
    static var blueLight: Color { Color.blueLight }
    static var purpleAccent: Color { Color.purpleAccent }
    static var purpleLight: Color { Color.purpleLight }
    static var gold: Color { Color.gold }
    static var goldLight: Color { Color.goldLight }
    static var warmSuccess: Color { Color.warmSuccess }
    static var warmWarning: Color { Color.warmWarning }
    static var warmError: Color { Color.warmError }
    static var warmInfo: Color { Color.warmInfo }
}

// MARK: - Backward-compatible aliases (warm* → adaptive*)

extension Color {
    static var warmBg: Color { adaptiveBgPrimary }
    static var warmBgSecondary: Color { adaptiveBgSecondary }
    static var warmBgTertiary: Color { adaptiveBgTertiary }
    static var warmBgElevated: Color { adaptiveBgElevated }
    static var warmInk: Color { adaptiveInk }
    static var warmInkLight: Color { adaptiveInkLight }
    static var warmInkFaint: Color { adaptiveInkFaint }
}

// MARK: - Typography

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let displayLarge  = Font.display(28)
    static let displayMedium = Font.display(22)
    static let displaySmall  = Font.display(18)

    static let bodyWarm    = Font.system(size: 13, weight: .medium)
    static let captionWarm = Font.system(size: 11, weight: .medium)
    static let labelWarm   = Font.system(size: 11, weight: .bold)
    static let monoWarm    = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: - Card Modifier (adapts to light/dark)

struct WarmCardModifier: ViewModifier {
    var padding: CGFloat
    var borderColor: Color
    var hasShadow: Bool

    init(padding: CGFloat = 14, borderColor: Color = .adaptiveBorderDim, hasShadow: Bool = true) {
        self.padding = padding
        self.borderColor = borderColor
        self.hasShadow = hasShadow
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.adaptiveBgSecondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
            .shadow(
                color: hasShadow ? Color.adaptiveInk.opacity(0.04) : .clear,
                radius: 2, x: 0, y: 1
            )
    }
}

extension View {
    func warmCard(padding: CGFloat = 14, border: Color = .adaptiveBorderDim) -> some View {
        modifier(WarmCardModifier(padding: padding, borderColor: border))
    }

    func warmCardAccent(_ accent: Color, padding: CGFloat = 14) -> some View {
        modifier(WarmCardModifier(padding: padding, borderColor: accent.opacity(0.3)))
    }
}

// MARK: - Status Badge

struct WarmBadge: View {
    let text: String
    let color: Color
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1.5))
    }
}

// MARK: - Button Style

struct WarmButtonStyle: ButtonStyle {
    var color: Color
    var filled: Bool

    init(_ color: Color = .adaptiveCoral, filled: Bool = true) {
        self.color = color
        self.filled = filled
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(filled ? .white : color)
            .background(filled ? color : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(filled ? color : color.opacity(0.4), lineWidth: 2)
            )
            .shadow(
                color: configuration.isPressed ? .clear : Color.adaptiveInk.opacity(0.06),
                radius: 0, x: 0, y: configuration.isPressed ? 0 : 1
            )
            .offset(
                x: configuration.isPressed ? 0 : 0,
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
    var iconColor: Color = .adaptiveCoral

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
                    .foregroundStyle(Color.adaptiveInkLight)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.adaptiveInk)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.captionWarm)
                    .foregroundStyle(Color.adaptiveInkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .warmCard(padding: 12)
    }
}

// MARK: - Section Header

struct WarmSectionHeader: View {
    let title: String
    var icon: String? = nil
    var color: Color = .adaptiveInk

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

// MARK: - DarkBloom Brand Name

struct DarkBloomBrand: View {
    var size: CGFloat = 18

    var body: some View {
        HStack(spacing: 0) {
            Text("Dark")
                .font(.display(size))
                .foregroundStyle(Color.adaptiveInk)
            Text("bloom")
                .font(.display(size))
                .foregroundStyle(Color.adaptiveBrand)
        }
    }
}

// MARK: - Background Modifier

struct WarmBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.adaptiveBgPrimary)
    }
}

extension View {
    func warmBackground() -> some View {
        modifier(WarmBackground())
    }
}
