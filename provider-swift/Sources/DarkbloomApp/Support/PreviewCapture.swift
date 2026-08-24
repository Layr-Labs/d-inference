#if DEBUG
import AppKit

@MainActor
enum PreviewCapture {
    static func captureIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        guard let path = environment["DARKBLOOM_RENDER_PREVIEW_PATH"] else {
            return
        }

        let requestedDelay = environment["DARKBLOOM_RENDER_PREVIEW_DELAY"]
            .flatMap(Double.init) ?? 1.2
        try? await Task.sleep(for: .seconds(requestedDelay))

        let url = URL(fileURLWithPath: path)
        for _ in 0 ..< 20 {
            if writeFirstWindow(to: url) {
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @discardableResult
    static func writeFirstWindow(to url: URL) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            return false
        }

        window.displayIfNeeded()
        guard let contentView = window.contentView,
              let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else {
            return false
        }

        contentView.layoutSubtreeIfNeeded()
        if let layer = contentView.layer,
           let context = NSGraphicsContext(bitmapImageRep: representation)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            layer.render(in: context.cgContext)
            NSGraphicsContext.restoreGraphicsState()
            if let png = representation.representation(using: .png, properties: [:]) {
                try? png.write(to: url, options: .atomic)
                return true
            }
        }

        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        if let png = representation.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
            return true
        }

        return false
    }
}
#endif
