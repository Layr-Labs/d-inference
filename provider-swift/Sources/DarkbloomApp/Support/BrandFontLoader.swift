import CoreText
import Foundation

enum BrandFontLoader {
    static func registerFonts() {
        registerFont(named: "Chivo-Regular", extension: "ttf")
        registerFont(named: "Chivo-Medium", extension: "ttf")
    }

    private static func registerFont(named name: String, extension fileExtension: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else {
            return
        }

        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}
