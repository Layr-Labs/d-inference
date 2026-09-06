import SwiftUI

/// Shared studio identity. The UI keeps the same contrast hierarchy in both
/// appearances; cobalt belongs to actions, not to every surface.
enum StudioPalette {
    static let canvas = adaptive(0xF8F9FD, 0x121624)
    static let surface = adaptive(0xFFFFFF, 0x1B2030)
    static let ink = adaptive(0x17203A, 0xF1F3FF)
    static let secondaryInk = adaptive(0x626A80, 0xADB6CE)
    static let accent = adaptive(0x3454E8, 0x9CADFF)
    static let accentSoft = adaptive(0xE9EDFF, 0x293352)
    static let line = adaptive(0xE1E5F0, 0x343D53)
    static let cobalt = Color(red: 52 / 255, green: 84 / 255, blue: 232 / 255)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255, alpha: 1
            )
        })
    }
}

struct StudioPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(StudioPalette.cobalt, in: RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
