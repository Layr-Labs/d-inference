import SwiftUI

enum DarkbloomTheme {
    // Figma: Darkbloom Identity / Layout1 _ Max (node 950:1756).
    static let canvas = Color.white
    static let ink = Color.black
    static let accent = Color(red: 49 / 255, green: 93 / 255, blue: 236 / 255)
    static let surface = Color(red: 247 / 255, green: 247 / 255, blue: 245 / 255)
    static let hairline = Color(red: 234 / 255, green: 234 / 255, blue: 232 / 255)
    static let nodePale = Color(red: 181 / 255, green: 204 / 255, blue: 255 / 255)

    static func chivo(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let fontName = weight == .medium ? "Chivo-Medium" : "Chivo-Regular"
        return .custom(fontName, size: size)
    }
}
