import AppKit
import ConnectCore
import SwiftUI

/// Developer-only rendering of this app's OWN views into image artifacts.
/// This does not capture the screen, inspect other apps, or unlock the Mac.
@MainActor
enum PreviewExporter {
    static func export(to directory: URL) async throws {
        let store = ConnectStore()
        await store.refresh()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for page in ConnectStore.Page.allCases {
            store.page = page
            let content = ContentView(store: store)
                .tint(.purple)
                .environment(\.colorScheme, .light)
                .frame(width: 1060, height: 800)
                // Offscreen bitmaps have no NSWindow compositor behind them.
                // Supply its surface so transparent regions remain legible.
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.appearance = NSAppearance(named: .aqua)
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw ConnectError.unavailable }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ConnectError.unavailable }
            try png.write(to: directory.appendingPathComponent("\(page)-preview.png"))
            window.close()
        }
    }
}
