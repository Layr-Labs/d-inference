import AppKit
import Testing
@testable import DarkbloomApp

@Suite("Chat composer measurement")
@MainActor
struct ChatComposerSizingTests {
    @Test("Minimum-window and unconstrained proposals always produce finite sizes")
    func finiteProposals() {
        let widths: [CGFloat?] = [nil, 0, -1, .infinity, .nan, 1, 620]
        for width in widths {
            let size = ChatComposerSizing.size(text: "A message", proposedWidth: width)
            #expect(size.width.isFinite && size.width > 0)
            #expect(size.height.isFinite && size.height >= 58 && size.height <= 148)
        }
    }

    @Test("Multiline drafts grow to the scrolling limit and repeated measurements stay stable")
    func multilineHeight() {
        let draft = "First line\nSecond line\nThird line\nFourth line\n"
        let oneLine = ChatComposerSizing.size(text: "Hello", proposedWidth: 400)
        let multiline = ChatComposerSizing.size(text: draft, proposedWidth: 400)
        #expect(multiline.height > oneLine.height)
        for _ in 0 ..< 10 {
            #expect(ChatComposerSizing.size(text: draft, proposedWidth: 400) == multiline)
        }
        #expect(ChatComposerSizing.size(
            text: String(repeating: "A long line\n", count: 100), proposedWidth: 400
        ).height == 148)
    }
}
