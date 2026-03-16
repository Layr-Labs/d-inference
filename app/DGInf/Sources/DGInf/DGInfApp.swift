/// DGInfApp — Main entry point for the DGInf macOS menu bar application.
///
/// This is a menu-bar-only app (no dock icon) that wraps the Rust
/// `dginf-provider` binary and makes it invisible to non-technical users.
/// It uses SwiftUI's MenuBarExtra (macOS 13+) to show a status icon in
/// the menu bar with a dropdown panel for quick actions.
///
/// Scenes:
///   - MenuBarExtra: The persistent menu bar icon and dropdown panel
///   - Settings: Standard macOS settings window (Cmd+,)
///   - Dashboard: Detailed statistics window

import SwiftUI

@main
struct DGInfApp: App {
    @StateObject private var viewModel = StatusViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(viewModel: viewModel)
        }

        Window("Dashboard", id: "dashboard") {
            DashboardView(viewModel: viewModel)
        }
    }

    /// The menu bar icon and optional throughput text.
    ///
    /// Shows a filled green circle when online, a hollow gray circle
    /// when offline, and appends the current tok/s when actively serving.
    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: viewModel.isOnline ? "circle.fill" : "circle")
                .foregroundColor(viewModel.isOnline ? .green : .gray)
            if viewModel.isServing {
                Text("\(viewModel.tokensPerSecond, specifier: "%.0f") tok/s")
                    .font(.caption)
            }
        }
    }
}
