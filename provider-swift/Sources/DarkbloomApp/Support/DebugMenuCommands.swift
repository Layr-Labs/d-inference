#if DEBUG
import SwiftUI

/// A development window for inspecting the same view used by MenuBarExtra.
/// It exercises real stores and routing; release builds omit both the command
/// and its window scene.
struct DebugMenuCommands: Commands {
    static let windowID = "debug-menu-preview"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Preview Menu Bar…") {
                openWindow(id: Self.windowID)
            }
            .keyboardShortcut("m", modifiers: [.command, .option, .control])
        }
    }
}
#endif
