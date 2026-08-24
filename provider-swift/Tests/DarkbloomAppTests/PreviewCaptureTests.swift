#if DEBUG
import AppKit
import Testing
@testable import DarkbloomApp

@Suite("Preview capture geometry")
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
}
#endif
