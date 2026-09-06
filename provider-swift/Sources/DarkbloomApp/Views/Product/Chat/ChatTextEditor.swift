import AppKit
import SwiftUI

/// Only text-system behavior crosses into AppKit: multiline layout, standard
/// editing/undo, IME composition, and exact Return/Shift-Return semantics.
struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let conversationID: UUID
    var minimumHeight: CGFloat = 58
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let editor = ChatInputTextView(frame: scroll.contentView.bounds)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Message Darkbloom")
        editor.setAccessibilityHelp("Return sends. Shift-Return inserts a new line.")
        scroll.documentView = editor
        context.coordinator.editor = editor
        update(editor, context: context)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let editor = nsView.documentView as? ChatInputTextView else { return }
        context.coordinator.parent = self
        update(editor, context: context)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        guard let editor = nsView.documentView as? ChatInputTextView else { return }
        editor.delegate = nil
        editor.onSubmit = nil
        editor.onFocusChange = nil
        editor.wantsComposerFocus = false
        coordinator.editor = nil
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        // Measurement must not resize the live text container or force layout:
        // SwiftUI also asks during its minimum-window constraint pass.
        let size = ChatComposerSizing.size(text: text, proposedWidth: proposal.width)
        return CGSize(width: size.width, height: max(minimumHeight, size.height))
    }

    private func update(_ editor: ChatInputTextView, context: Context) {
        editor.replaceDraft(text, conversationID: conversationID)
        editor.onSubmit = onSubmit
        editor.wantsComposerFocus = isFocused
        editor.onFocusChange = { [weak coordinator = context.coordinator] focused in
            DispatchQueue.main.async {
                // A replaced editor must not replay focus into the new session.
                guard let coordinator, let editor = coordinator.editor,
                      let window = editor.window,
                      (window.firstResponder === editor) == focused
                else { return }
                coordinator.parent.isFocused = focused
            }
        }
        if isFocused, let window = editor.window, window.firstResponder !== editor {
            // Do not change first responder in the middle of a SwiftUI update.
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.wantsComposerFocus, let window = editor.window,
                      window.firstResponder !== editor
                else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditor
        weak var editor: NSTextView?

        init(_ parent: ChatTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor else { return }
            parent.text = editor.string
        }
    }
}

/// Text input must handle marked text first: Return commits an IME candidate
/// before it can send a message. Other editing shortcuts keep AppKit behavior.
final class ChatInputTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var wantsComposerFocus = false
    private var conversationID: UUID?
    private let draftUndoManager = UndoManager()

    // Keep undo local to this editor, including when no window is attached.
    override var undoManager: UndoManager? { draftUndoManager }

    func replaceDraft(_ text: String, conversationID: UUID) {
        guard self.conversationID != conversationID || string != text else { return }
        self.conversationID = conversationID
        if hasMarkedText() { unmarkText() }
        string = text
        // Equal-text history restores still cross a conversation boundary.
        draftUndoManager.removeAllActions()
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        switch ChatInputKeyAction.resolve(
            keyCode: event.keyCode, modifiers: event.modifierFlags, hasMarkedText: hasMarkedText()
        ) {
        case .submit: onSubmit?()
        case .newline: insertNewlineIgnoringFieldEditor(nil)
        case .system: super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsComposerFocus { window?.makeFirstResponder(self) }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}
