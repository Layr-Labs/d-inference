import AppKit
import Testing
@testable import DarkbloomApp

@Suite("Chat editor input and conversation boundaries")
@MainActor
struct ChatTextEditorTests {
    @Test("Marked text keeps every Return variant in the native input system")
    func markedTextDoesNotSubmit() {
        let modifiers: [NSEvent.ModifierFlags] = [[], .shift, .option, .command, .control, [.command, .shift]]
        for keyCode in [UInt16(36), UInt16(76)] {
            for flags in modifiers {
                #expect(ChatInputKeyAction.resolve(
                    keyCode: keyCode, modifiers: flags, hasMarkedText: true
                ) == .system)
            }
        }
    }

    @Test("Return submits, Shift/Option-Return inserts a line, and other editing stays native")
    func keyboardActions() {
        for keyCode in [UInt16(36), UInt16(76)] {
            #expect(ChatInputKeyAction.resolve(keyCode: keyCode, modifiers: [], hasMarkedText: false) == .submit)
            #expect(ChatInputKeyAction.resolve(keyCode: keyCode, modifiers: .command, hasMarkedText: false) == .submit)
            #expect(ChatInputKeyAction.resolve(keyCode: keyCode, modifiers: .shift, hasMarkedText: false) == .newline)
            #expect(ChatInputKeyAction.resolve(keyCode: keyCode, modifiers: .option, hasMarkedText: false) == .newline)
            #expect(ChatInputKeyAction.resolve(keyCode: keyCode, modifiers: .control, hasMarkedText: false) == .system)
        }
        #expect(ChatInputKeyAction.resolve(keyCode: 0, modifiers: .command, hasMarkedText: false) == .system)
    }

    @Test("Equal drafts in different conversations cannot reuse undo actions")
    func equalDraftsResetUndo() throws {
        // No NSApplication, window, focus changes, or synthetic input events.
        let editor = ChatInputTextView(frame: .zero)
        let firstID = UUID()
        editor.replaceDraft("Shared draft", conversationID: firstID)
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: editor) { $0.string = "Private text from the first conversation" }
        undo.endUndoGrouping()
        #expect(undo.canUndo)

        editor.replaceDraft("Shared draft", conversationID: firstID)
        #expect(undo.canUndo) // An ordinary binding echo must preserve editing undo.
        editor.replaceDraft("Shared draft", conversationID: UUID())
        #expect(!undo.canUndo)
        #expect(!undo.canRedo)
        #expect(editor.string == "Shared draft")
    }

    @Test("Sending or replacing a draft clears its undo without affecting another editor")
    func replacementsHaveLocalUndo() throws {
        let first = ChatInputTextView(frame: .zero)
        let second = ChatInputTextView(frame: .zero)
        let id = UUID()
        first.replaceDraft("First", conversationID: id)
        second.replaceDraft("Second", conversationID: UUID())
        for editor in [first, second] {
            let undo = try #require(editor.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: editor) { $0.string = "Earlier text" }
            undo.endUndoGrouping()
        }
        first.replaceDraft("", conversationID: id)
        #expect(first.undoManager?.canUndo == false)
        #expect(second.undoManager?.canUndo == true)
    }
}
