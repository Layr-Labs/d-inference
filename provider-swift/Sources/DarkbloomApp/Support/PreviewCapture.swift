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
        if requestedDelay > 0 {
            try? await Task.sleep(for: .seconds(requestedDelay))
        }

        let url = URL(fileURLWithPath: path)
        for _ in 0 ..< 20 {
            if writeFirstWindow(to: url) {
                NSApp.terminate(nil)
                return
            }
            await Task.yield()
        }

        NSApp.terminate(nil)
    }

    @discardableResult
    static func writeFirstWindow(to url: URL) -> Bool {
        guard let window = previewWindow(),
              let root = window.contentView
        else {
            return false
        }

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        root.needsLayout = true
        root.needsDisplay = true
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        window.displayIfNeeded()

        guard let representation = renderCachedDisplay(root) else {
            return false
        }

        let descendants = viewDescendants(root)
        let hasMountedSidebar = descendants.contains {
            className($0).contains("SidebarStyleContext")
        }
        if hasMountedSidebar {
            guard let outline = sidebarOutline(in: descendants, root: root),
                  composite(outline, onto: representation, in: root)
            else {
                return false
            }
        }

        guard hasNontrivialPixels(representation),
              let png = representation.representation(using: .png, properties: [:])
        else {
            return false
        }

        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func bitmapDestination(
        frameInRoot: NSRect,
        rootBounds: NSRect,
        rootIsFlipped: Bool,
        contextIsFlipped: Bool
    ) -> NSRect {
        var destination = frameInRoot.offsetBy(
            dx: -rootBounds.minX,
            dy: -rootBounds.minY
        )
        if rootIsFlipped != contextIsFlipped {
            destination.origin.y = rootBounds.height - destination.maxY
        }
        return destination
    }

    private static func previewWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.identifier?.rawValue == "dev.darkbloom.main-window"
        } ?? NSApp.windows.first {
            $0.isVisible && $0.level == .normal
        }
    }

    private static func renderCachedDisplay(_ view: NSView) -> NSBitmapImageRep? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation
    }

    private static func sidebarOutline(
        in descendants: [NSView],
        root: NSView
    ) -> NSView? {
        descendants
            .filter { className($0) == "SwiftUIOutlineListView" }
            .min {
                root.convert($0.bounds, from: $0).minX
                    < root.convert($1.bounds, from: $1).minX
            }
    }

    private static func composite(
        _ overlay: NSView,
        onto base: NSBitmapImageRep,
        in root: NSView
    ) -> Bool {
        overlay.layoutSubtreeIfNeeded()
        overlay.displayIfNeeded()
        guard let overlayRepresentation = renderCachedDisplay(overlay),
              root.bounds.width > 0,
              root.bounds.height > 0
        else {
            return false
        }

        let scaleX = CGFloat(base.pixelsWide) / root.bounds.width
        let scaleY = CGFloat(base.pixelsHigh) / root.bounds.height
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX > 0,
              scaleY > 0
        else {
            return false
        }

        // Preserve point-space geometry while the bitmap context maps it to
        // the root's backing-pixel scale.
        base.size = root.bounds.size
        overlayRepresentation.size = overlay.bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: base) else {
            return false
        }

        let frameInRoot = root.convert(overlay.bounds, from: overlay)
        let destination = bitmapDestination(
            frameInRoot: frameInRoot,
            rootBounds: root.bounds,
            rootIsFlipped: root.isFlipped,
            contextIsFlipped: context.isFlipped
        )
        guard !destination.isEmpty else {
            return false
        }

        let image = NSImage(size: overlay.bounds.size)
        image.addRepresentation(overlayRepresentation)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(
            in: destination,
            from: NSRect(origin: .zero, size: overlay.bounds.size),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
        return true
    }

    private static func hasNontrivialPixels(_ representation: NSBitmapImageRep) -> Bool {
        guard representation.pixelsWide > 0,
              representation.pixelsHigh > 0
        else {
            return false
        }

        let stepX = max(1, representation.pixelsWide / 64)
        let stepY = max(1, representation.pixelsHigh / 64)
        var sampled = 0
        var visible = 0
        var colors = Set<UInt32>()

        for y in stride(from: 0, to: representation.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: representation.pixelsWide, by: stepX) {
                guard let color = representation.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB)
                else {
                    continue
                }

                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                sampled += 1
                if alpha > 0.01 {
                    visible += 1
                }

                let rgba = [red, green, blue, alpha].map {
                    UInt32(max(0, min(255, Int(($0 * 255).rounded()))))
                }
                colors.insert(
                    (rgba[0] << 24) | (rgba[1] << 16) | (rgba[2] << 8) | rgba[3]
                )
            }
        }

        return sampled >= 64
            && visible * 4 >= sampled * 3
            && colors.count >= 16
    }

    private static func viewDescendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(viewDescendants)
    }

    private static func className(_ view: NSView) -> String {
        String(describing: type(of: view))
    }
}
#endif
