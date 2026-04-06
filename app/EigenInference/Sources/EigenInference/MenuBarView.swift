/// MenuBarView — The dropdown UI shown when clicking the EigenInference menu bar icon.
///
/// Shows at-a-glance provider status with quick actions.
/// Uses Liquid Glass on macOS 26+, falls back to .ultraThinMaterial on older versions.

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                HStack(spacing: 0) {
                    Text("Eigen")
                        .font(.displaySmall)
                        .foregroundStyle(Color.warmInk)
                    Text("Inference")
                        .font(.displaySmall)
                        .foregroundStyle(Color.coral)
                }
                Circle()
                    .fill(viewModel.coordinatorConnected ? Color.tealAccent : Color.warmError)
                    .frame(width: 6, height: 6)
                    .help(viewModel.coordinatorConnected ? "Coordinator connected" : "Coordinator offline")
                Spacer()
                statusBadge
            }

            Divider()

            // Hardware + model info
            VStack(alignment: .leading, spacing: 6) {
                Text("\(viewModel.chipName) \u{00B7} \(viewModel.memoryGB) GB")
                    .font(.bodyWarm)
                    .foregroundStyle(Color.warmInkLight)

                // Current model (auto-selected, configurable in Settings)
                HStack {
                    Text("Model:")
                        .foregroundStyle(Color.warmInkLight)
                    Text(viewModel.currentModel.components(separatedBy: "/").last ?? viewModel.currentModel)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.warmInk)
                        .lineLimit(1)
                }
                .font(.bodyWarm)

                // Live status with animated throughput
                HStack {
                    Text("Status:")
                        .foregroundStyle(Color.warmInkLight)
                    statusText
                }
                .font(.bodyWarm)
                .animation(.smooth, value: viewModel.isServing)

                // Trust level
                HStack(spacing: 4) {
                    Text("Trust:")
                        .foregroundStyle(Color.warmInkLight)
                    Image(systemName: viewModel.securityManager.trustLevel.iconName)
                        .foregroundStyle(trustColor)
                    Text(viewModel.securityManager.trustLevel.displayName)
                        .foregroundStyle(trustColor)
                }
                .font(.bodyWarm)
            }

            // Trust warnings
            trustWarning

            Divider()

            // Stats
            if viewModel.requestsServed > 0 || viewModel.tokensGenerated > 0 {
                HStack {
                    Text("Today:")
                        .foregroundStyle(Color.warmInkLight)
                    Text("\(viewModel.requestsServed) requests")
                        .foregroundStyle(Color.warmInk)
                    Text("\u{00B7}")
                        .foregroundStyle(Color.warmInkFaint)
                    Text(formatTokenCount(viewModel.tokensGenerated))
                        .foregroundStyle(Color.warmInk)
                }
                .font(.bodyWarm)
                .contentTransition(.numericText())
            }

            if !viewModel.earningsBalance.isEmpty {
                HStack {
                    Text("Earnings:")
                        .foregroundStyle(Color.warmInkLight)
                    Text(viewModel.earningsBalance)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.tealAccent)
                }
                .font(.bodyWarm)
            }

            if viewModel.isOnline {
                HStack {
                    Text("Uptime:")
                        .foregroundStyle(Color.warmInkLight)
                    Text(formatUptime(viewModel.uptimeSeconds))
                        .monospacedDigit()
                        .foregroundStyle(Color.warmInk)
                }
                .font(.bodyWarm)
            }

            Divider()

            // On/Off toggle
            providerToggle

            // Sleep prevention
            if viewModel.providerManager.isRunning {
                Label("Sleep prevention active", systemImage: "bolt.shield")
                    .font(.captionWarm)
                    .foregroundStyle(Color.warmInkFaint)
            }

            // Pause/Resume
            if viewModel.isOnline && !viewModel.isPaused {
                Button(action: { viewModel.pauseProvider() }) {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.plain)
            } else if viewModel.isPaused {
                Button(action: { viewModel.resumeProvider() }) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Navigation
            navigationButtons

            Divider()

            // Footer
            HStack {
                Text("v\(viewModel.updateManager.currentVersion)")
                    .font(.captionWarm)
                    .foregroundStyle(Color.warmInkFaint)
                if viewModel.updateManager.updateAvailable {
                    Text("Update available")
                        .font(.captionWarm)
                        .foregroundStyle(Color.gold)
                }
                Spacer()
            }

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit EigenInference", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
        .background(Color.warmBg)
        .animation(.smooth, value: viewModel.isOnline)
        .animation(.smooth, value: viewModel.isPaused)
    }

    // MARK: - Components

    private var statusBadge: some View {
        WarmBadge(
            text: statusLabel,
            color: statusColor,
            icon: viewModel.isPaused ? "pause.fill" : viewModel.isOnline ? "bolt.fill" : "power"
        )
    }

    @ViewBuilder
    private var trustWarning: some View {
        if viewModel.securityManager.trustLevel != .hardware {
            Button(action: { openWindow(id: "setup") }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Complete setup for inference routing \u{2192}")
                }
                .font(.captionWarm)
                .foregroundStyle(Color.warmError)
            }
            .buttonStyle(.plain)
        }
    }

    private var providerToggle: some View {
        Toggle(isOn: Binding(
            get: { viewModel.isOnline || viewModel.providerManager.isRunning },
            set: { newValue in
                if newValue { viewModel.start() } else { viewModel.stop() }
            }
        )) {
            Text(viewModel.isOnline ? "Online" : viewModel.providerManager.isRunning ? "Starting..." : "Offline")
                .font(.bodyWarm)
                .foregroundStyle(Color.warmInk)
        }
        .toggleStyle(.switch)
        .tint(.tealAccent)
        .padding(8)
        .pointerOnHover()
    }

    @ViewBuilder
    private var navigationButtons: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                navButtonStack
            }
        } else {
            navButtonStack
        }
    }

    private var navButtonStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            navButton("Dashboard...", icon: "chart.bar", window: "dashboard")
            navButton("Logs...", icon: "doc.text", window: "logs")
            if !viewModel.hasCompletedSetup {
                navButton("Setup Wizard...", icon: "wrench", window: "setup")
            }
            Button(action: { openSettings() }) {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .modifier(InteractiveGlassModifier())
            .pointerOnHover()
        }
    }

    private func navButton(_ title: String, icon: String, window: String) -> some View {
        Button(action: { openWindow(id: window) }) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.plain)
        .modifier(InteractiveGlassModifier())
        .pointerOnHover()
    }

    private var statusText: some View {
        Group {
            if viewModel.isPaused {
                Text("Paused (user active)")
                    .foregroundStyle(Color.gold)
            } else if viewModel.isServing {
                HStack(spacing: 4) {
                    Text("Serving")
                        .foregroundStyle(Color.tealAccent)
                    Text("\u{00B7}")
                        .foregroundStyle(Color.warmInkFaint)
                    Text(String(format: "%.0f tok/s", viewModel.tokensPerSecond))
                        .foregroundStyle(Color.tealAccent)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else if viewModel.isOnline {
                Text("Ready")
                    .foregroundStyle(Color.tealAccent)
            } else {
                Text("Stopped")
                    .foregroundStyle(Color.warmInkFaint)
            }
        }
    }

    // MARK: - Helpers

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .tealAccent
        case .none: return .warmError
        }
    }

    private var statusColor: Color {
        if viewModel.isPaused { return .gold }
        if viewModel.isOnline { return .tealAccent }
        return .warmInkFaint
    }

    private var statusLabel: String {
        if viewModel.isPaused { return "Paused" }
        if viewModel.isOnline { return "Online" }
        return "Offline"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM tokens", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK tokens", Double(count) / 1_000) }
        return "\(count) tokens"
    }

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - Glass Modifiers (macOS 26+ with fallback)

/// Applies Liquid Glass on macOS 26+, subtle material background on older versions.
private struct GlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color?

    init(shape: S, tint: Color? = nil) {
        self.shape = shape
        self.tint = tint
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(in: shape)
            }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Interactive glass for buttons — Liquid Glass on 26+, plain on older.
private struct InteractiveGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive())
        } else {
            content
        }
    }
}
