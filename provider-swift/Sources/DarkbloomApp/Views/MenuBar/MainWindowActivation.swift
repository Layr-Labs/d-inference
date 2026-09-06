import AppKit
import SwiftUI

private extension NSUserInterfaceItemIdentifier {
    static let darkbloomMainWindow = NSUserInterfaceItemIdentifier("dev.darkbloom.main-window")
}

@MainActor
enum DarkbloomApplicationBridge {
    static func openOrActivateMainWindow(using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.identifier == .darkbloomMainWindow }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    static func quitApp() {
        NSApp.terminate(nil)
    }
}

struct DarkbloomMainWindowTag: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        MainWindowTaggingView()
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        nsView.window?.identifier = .darkbloomMainWindow
    }
}

@MainActor
private final class MainWindowTaggingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = .darkbloomMainWindow
    }
}
