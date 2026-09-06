import SwiftUI

enum DarkbloomTheme {
    // Preserve the identity's paper-and-cobalt palette in light appearance,
    // with a matching dark canvas instead of forcing a white setup window.
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.075, green: 0.085, blue: 0.12, alpha: 1)
            : .white
    })
    static let ink = Color.primary
    static let accent = Color(red: 49 / 255, green: 93 / 255, blue: 236 / 255)
    static let linkAccent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.68, blue: 1, alpha: 1)
            : NSColor(srgbRed: 49 / 255, green: 93 / 255, blue: 236 / 255, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let nodePale = Color(red: 181 / 255, green: 204 / 255, blue: 255 / 255)

    static func chivo(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = weight == .medium ? "Chivo-Medium" : "Chivo-Regular"
        return .custom(fontName, size: size)
    }
}
