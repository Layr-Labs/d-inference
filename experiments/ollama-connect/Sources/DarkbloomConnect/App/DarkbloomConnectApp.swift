import AppKit
import SwiftUI

@main
struct DarkbloomConnectApp: App {
    @NSApplicationDelegateAdaptor(ConnectAppDelegate.self) private var delegate
    @State private var store = ConnectStore()

    var body: some Scene {
        WindowGroup("Darkbloom Connect", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 940, minHeight: 670)
                .tint(.purple)
                .task { await store.monitor() }
        }
        .defaultSize(width: 1060, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh connection") { Task { await store.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

final class ConnectAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--export-preview"), index + 1 < CommandLine.arguments.count {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try await PreviewExporter.export(to: directory) }
                catch { fputs("Preview export failed.\n", stderr) }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
