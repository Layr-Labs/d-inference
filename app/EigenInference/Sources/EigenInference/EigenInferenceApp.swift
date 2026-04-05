/// EigenInferenceApp — Main entry point for the EigenInference macOS menu bar application.
///
/// Menu-bar-only app (no dock icon) that wraps the Rust `eigeninference-provider`
/// binary. Uses SwiftUI's MenuBarExtra (macOS 13+) for the status icon.
///
/// Activation policy management:
///   When only the menu bar is showing → .accessory (no dock icon)
///   When any window is open → .regular (dock icon, full focus, text selectable)
///   When last window closes → back to .accessory
///
/// Scenes:
///   - MenuBarExtra: Persistent menu bar icon and dropdown
///   - Settings: Standard macOS settings window (Cmd+,)
///   - Dashboard: Detailed statistics window
///   - Setup: First-run onboarding wizard
///   - Doctor: Diagnostic results
///   - Logs: Streaming log viewer
///   - Logs: Provider log viewer

import SwiftUI

@main
struct EigenInferenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                .textSelection(.enabled)
        }

        Window("Setup", id: "setup") {
            SetupWizardView(viewModel: viewModel)
                .textSelection(.enabled)
        }

        Window("Diagnostics", id: "doctor") {
            DoctorView(viewModel: viewModel)
                .textSelection(.enabled)
        }

        Window("Logs", id: "logs") {
            LogViewerView(viewModel: viewModel)
                .textSelection(.enabled)
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

// MARK: - AppDelegate (activation policy management)

/// Manages the app's activation policy so windows behave like a real app.
///
/// Menu-bar-only SwiftUI apps run as `.accessory` by default, which means
/// windows don't receive focus, text isn't selectable, and windows layer
/// behind other apps. This delegate watches for window open/close events
/// and switches to `.regular` when any window is visible, giving the app
/// full focus, a dock icon, and proper window management.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as accessory (no dock icon, menu bar only)
        NSApplication.shared.setActivationPolicy(.accessory)

        // Watch for windows appearing/disappearing
        let center = NotificationCenter.default

        observers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.activateIfNeeded()
            }
        )

        observers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delay slightly so the window has time to close
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.deactivateIfNoWindows()
                }
            }
        )
    }

    /// Switch to .regular and activate when a real window appears.
    private func activateIfNeeded() {
        guard hasVisibleWindows() else { return }
        if NSApplication.shared.activationPolicy() != .regular {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Switch back to .accessory when all windows are closed.
    private func deactivateIfNoWindows() {
        guard !hasVisibleWindows() else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Check if any "real" windows are visible (excludes menu bar panels, status items, etc.)
    private func hasVisibleWindows() -> Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible
            && window.level == .normal
            && !(window is NSPanel)
            && window.styleMask.contains(.titled)
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
