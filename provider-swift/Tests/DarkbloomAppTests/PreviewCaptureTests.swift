#if DEBUG
import AppKit
import Testing
@testable import DarkbloomApp

@Suite("Preview capture compositing")
@MainActor
struct PreviewCaptureTests {
    @Test("Flipped root coordinates map into an unflipped bitmap")
    func flippedRootCoordinatesMapIntoBitmap() {
        let destination = PreviewCapture.bitmapDestination(
            frameInRoot: NSRect(x: 8, y: 95, width: 210, height: 577),
            rootBounds: NSRect(x: 0, y: 0, width: 1_040, height: 680),
            rootIsFlipped: true,
            contextIsFlipped: false
        )

        #expect(destination == NSRect(x: 8, y: 8, width: 210, height: 577))
    }

    @Test("Matching coordinate orientations preserve normalized placement")
    func matchingOrientationsPreservePlacement() {
        let destination = PreviewCapture.bitmapDestination(
            frameInRoot: NSRect(x: 18, y: 35, width: 100, height: 200),
            rootBounds: NSRect(x: 10, y: 20, width: 500, height: 400),
            rootIsFlipped: true,
            contextIsFlipped: true
        )

        #expect(destination == NSRect(x: 8, y: 15, width: 100, height: 200))
    }

    @Test("AppKit outline pixels and text composite opaquely at subtree coordinates")
    func appKitOutlineCompositeIsVisibleAndPlaced() {
        let root = GradientFixtureView(frame: NSRect(x: 0, y: 0, width: 180, height: 130))
        let container = FlippedFixtureView(
            frame: NSRect(x: 24, y: 18, width: 132, height: 96)
        )
        let outline = OutlineFixtureView(
            frame: NSRect(x: 12, y: 14, width: 92, height: 58)
        )
        let label = NSTextField(labelWithString: "OUTLINE PIXELS")
        label.frame = NSRect(x: 8, y: 18, width: 76, height: 22)
        label.font = .boldSystemFont(ofSize: 12)
        label.textColor = .white
        label.alignment = .center

        outline.addSubview(label)
        container.addSubview(outline)
        root.addSubview(container)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        root.layoutSubtreeIfNeeded()

        // Model the production failure mode: the cached SwiftUI root misses // pragma: allowlist secret
        // the outline's layer-backed pixels, then the dedicated outline pass
        // must restore them.
        outline.isHidden = true
        guard let composite = PreviewCapture.renderCachedDisplay(root) else {
            Issue.record("could not render the AppKit root fixture")
            return
        }
        outline.isHidden = false
        guard let context = NSGraphicsContext(bitmapImageRep: composite) else {
            Issue.record("could not construct the bitmap context")
            return
        }

        let frameInRoot = root.convert(outline.bounds, from: outline)
        let destination = PreviewCapture.bitmapDestination(
            frameInRoot: frameInRoot,
            rootBounds: root.bounds,
            rootIsFlipped: root.isFlipped,
            contextIsFlipped: context.isFlipped
        )
        let insidePoint = NSPoint(x: destination.minX + 4, y: destination.minY + 4)
        let outsidePoint = NSPoint(x: destination.maxX + 8, y: destination.minY + 4)
        let insideBefore = fixtureColor(
            in: composite,
            at: insidePoint,
            canvas: root.bounds
        )
        let outsideBefore = fixtureColor(
            in: composite,
            at: outsidePoint,
            canvas: root.bounds
        )

        #expect(PreviewCapture.composite(outline, onto: composite, in: root))
        #expect(PreviewCapture.hasNontrivialPixels(composite))
        #expect(bitmapIsOpaque(composite))

        guard let insideAfter = fixtureColor(
            in: composite,
            at: insidePoint,
            canvas: root.bounds
        ), let outsideAfter = fixtureColor(
            in: composite,
            at: outsidePoint,
            canvas: root.bounds
        ) else {
            Issue.record("could not sample the final composite")
            return
        }
        #expect(insideBefore != nil)
        #expect(insideAfter.blueComponent > 0.65)
        #expect(insideAfter.blueComponent > insideAfter.redComponent * 2)
        #expect(colorsApproximatelyEqual(outsideBefore, outsideAfter))
        #expect(brightPixelCount(
            in: composite,
            pointRect: destination,
            canvas: root.bounds
        ) > 4)
    }
}

@MainActor
private class FlippedFixtureView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class GradientFixtureView: FlippedFixtureView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let columns = max(1, Int(bounds.width.rounded(.up)))
        for column in 0 ..< columns {
            let fraction = CGFloat(column) / CGFloat(columns)
            NSColor(
                calibratedRed: 0.18 + fraction * 0.56,
                green: 0.12 + fraction * 0.18,
                blue: 0.08,
                alpha: 1
            ).setFill()
            NSRect(
                x: CGFloat(column),
                y: bounds.minY,
                width: 1,
                height: bounds.height
            ).fill()
        }
    }
}

@MainActor
private final class OutlineFixtureView: FlippedFixtureView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.86, alpha: 1).setFill()
        bounds.fill()
    }
}

@MainActor
private func fixtureColor(
    in bitmap: NSBitmapImageRep,
    at point: NSPoint,
    canvas: NSRect
) -> NSColor? {
    guard canvas.width > 0, canvas.height > 0 else { return nil }
    let x = Int(((point.x - canvas.minX) / canvas.width) * CGFloat(bitmap.pixelsWide))
    let y = Int(((point.y - canvas.minY) / canvas.height) * CGFloat(bitmap.pixelsHigh))
    guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh else {
        return nil
    }
    return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
}

@MainActor
private func bitmapIsOpaque(_ bitmap: NSBitmapImageRep) -> Bool {
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB),
                color.alphaComponent >= 0.99
            else {
                return false
            }
        }
    }
    return true
}

@MainActor
private func colorsApproximatelyEqual(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard let lhs = lhs?.usingColorSpace(.deviceRGB) else { return false }
    return abs(lhs.redComponent - rhs.redComponent) < 0.03
        && abs(lhs.greenComponent - rhs.greenComponent) < 0.03
        && abs(lhs.blueComponent - rhs.blueComponent) < 0.03
        && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.03
}

@MainActor
private func brightPixelCount(
    in bitmap: NSBitmapImageRep,
    pointRect: NSRect,
    canvas: NSRect
) -> Int {
    let minX = max(
        0,
        Int(((pointRect.minX - canvas.minX) / canvas.width) * CGFloat(bitmap.pixelsWide))
    )
    let maxX = min(
        bitmap.pixelsWide,
        Int(((pointRect.maxX - canvas.minX) / canvas.width) * CGFloat(bitmap.pixelsWide))
    )
    let minY = max(
        0,
        Int(((pointRect.minY - canvas.minY) / canvas.height) * CGFloat(bitmap.pixelsHigh))
    )
    let maxY = min(
        bitmap.pixelsHigh,
        Int(((pointRect.maxY - canvas.minY) / canvas.height) * CGFloat(bitmap.pixelsHigh))
    )
    var count = 0
    for y in minY ..< maxY {
        for x in minX ..< maxX {
            guard let color = bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.deviceRGB)
            else {
                continue
            }
            if color.redComponent > 0.72,
               color.greenComponent > 0.72,
               color.blueComponent > 0.72,
               color.alphaComponent > 0.95
            {
                count += 1
            }
        }
    }
    return count
}
#endif
