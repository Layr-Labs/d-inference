#if DEBUG
import AppKit

enum PreviewAppearance {
    @MainActor
    static func applyIfRequested(
        to application: NSApplication,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        switch environment["DARKBLOOM_PREVIEW_APPEARANCE"]?.lowercased() {
        case "dark":
            application.appearance = NSAppearance(named: .darkAqua)
        case "light":
            application.appearance = NSAppearance(named: .aqua)
        default:
            break
        }
    }
}
#endif
