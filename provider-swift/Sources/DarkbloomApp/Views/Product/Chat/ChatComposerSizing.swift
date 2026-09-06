import AppKit

@MainActor
enum ChatComposerSizing {
    static func size(text: String, proposedWidth: CGFloat?) -> CGSize {
        let width = proposedWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 320
        // Reserve the legacy scrollbar width and include the trailing caret
        // line. This calculation never touches the editor's layout manager.
        let measuredText = text.isEmpty || text.hasSuffix("\n") ? text + " " : text
        let bounds = (measuredText as NSString).boundingRect(
            with: CGSize(width: max(1, width - 16), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        )
        return CGSize(width: width, height: min(148, max(58, ceil(bounds.height + 12))))
    }
}
