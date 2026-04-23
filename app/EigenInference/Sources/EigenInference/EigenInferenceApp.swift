/// DarkBloomApp — Main entry point for the Darkbloom macOS menu bar application.
///
/// Menu-bar-only app (no dock icon) that wraps the Rust `darkbloom`
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
struct DarkBloomApp: App {
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

    private var eigenLogo: NSImage? {
        guard let url = Bundle.module.url(forResource: "MenuBarIcon@2x", withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let bitmap = NSBitmapImageRep(data: data),
              let cgImage = bitmap.cgImage else { return nil }
        let icon = NSImage(cgImage: cgImage, size: NSSize(width: 18, height: 18))
        icon.isTemplate = true
        return icon
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            if let logo = eigenLogo {
                Image(nsImage: logo)
                    .frame(width: 18, height: 18)
                    .clipped()
            } else {
                Image(systemName: "circle")
                    .foregroundColor(menuBarColor)
            }
            if viewModel.isServing {
                Text(formatThroughput(viewModel.tokensPerSecond))
                    .font(.captionWarm)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if viewModel.updateManager.updateAvailable {
                Circle()
                    .fill(Color.adaptiveGold)
                    .frame(width: 6, height: 6)
            }
        }
        .animation(.smooth, value: viewModel.isServing)
        .animation(.smooth, value: viewModel.tokensPerSecond)
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

        // Wire the telemetry reporter as early as possible so even
        // initialization errors can be reported.
        configureTelemetry()

        // Uncaught Objective-C exceptions — rare in Swift but still possible
        // when bridging into AppKit.
        NSSetUncaughtExceptionHandler { exception in
            TelemetryReporter.shared.emit(
                kind: .panic,
                severity: .fatal,
                message: "uncaught NSException: \(exception.name.rawValue)",
                fields: [
                    "component": "app",
                    "reason": "ns_exception",
                    "error": exception.reason ?? "<no reason>",
                ],
                stack: exception.callStackSymbols.joined(separator: "\n")
            )
            TelemetryReporter.shared.flushNow()
        }

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

    /// Configure TelemetryReporter with the coordinator URL derived from the
    /// provider config. We intentionally accept a plain HTTPS base URL even
    /// though the provider config uses `wss://` for the WebSocket — the
    /// telemetry endpoint lives on a different scheme/path.
    private func configureTelemetry() {
        let cfg = ConfigManager.load()
        // provider config holds something like "wss://api.darkbloom.dev/ws/provider".
        // Convert to the HTTPS base the ingest endpoint lives under.
        let httpsBase = Self.httpsBase(from: cfg.coordinatorURL)
        TelemetryReporter.shared.coordinatorBaseURL = httpsBase
    }

    /// Translate a `wss://host[:port]/...` URL into `https://host[:port]/`.
    /// Falls back to the production endpoint if parsing fails.
    static func httpsBase(from ws: String) -> URL? {
        guard var comps = URLComponents(string: ws) else {
            return URL(string: "https://api.darkbloom.dev")
        }
        comps.path = ""
        comps.query = nil
        switch comps.scheme {
        case "wss": comps.scheme = "https"
        case "ws": comps.scheme = "http"
        default: break
        }
        return comps.url
    }
}
