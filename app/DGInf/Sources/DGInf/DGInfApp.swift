/// DGInfApp — Main entry point for the DGInf macOS menu bar application.
///
/// Menu-bar-only app (no dock icon) that wraps the Rust `dginf-provider`
/// binary. Uses SwiftUI's MenuBarExtra (macOS 13+) for the status icon.
///
/// Scenes:
///   - MenuBarExtra: Persistent menu bar icon and dropdown
///   - Settings: Standard macOS settings window (Cmd+,)
///   - Dashboard: Detailed statistics window
///   - Setup: First-run onboarding wizard
///   - Doctor: Diagnostic results
///   - Logs: Streaming log viewer
///   - Wallet: Wallet and earnings display

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

        Window("Setup", id: "setup") {
            SetupWizardView(viewModel: viewModel)
        }

        Window("Diagnostics", id: "doctor") {
            DoctorView(viewModel: viewModel)
        }

        Window("Logs", id: "logs") {
            LogViewerView(viewModel: viewModel)
        }

        Window("Wallet", id: "wallet") {
            WalletView(viewModel: viewModel)
        }

        Window("Benchmark", id: "benchmark") {
            BenchmarkView(viewModel: viewModel)
        }
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: menuBarIcon)
                .foregroundColor(menuBarColor)
                .symbolEffect(.pulse, isActive: viewModel.isServing)
            if viewModel.isServing {
                Text(formatThroughput(viewModel.tokensPerSecond))
                    .font(.caption)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if viewModel.updateManager.updateAvailable {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.smooth, value: viewModel.isServing)
        .animation(.smooth, value: viewModel.tokensPerSecond)
    }

    private var menuBarIcon: String {
        if viewModel.isPaused { return "pause.circle.fill" }
        if viewModel.isServing { return "bolt.circle.fill" }
        if viewModel.isOnline { return "circle.fill" }
        return "circle"
    }

    private var menuBarColor: Color {
        if viewModel.isPaused { return .yellow }
        if viewModel.isOnline { return .green }
        return .gray
    }

    private func formatThroughput(_ tps: Double) -> String {
        if tps >= 1000 { return String(format: "%.1fK tok/s", tps / 1000) }
        return String(format: "%.0f tok/s", tps)
    }
}
