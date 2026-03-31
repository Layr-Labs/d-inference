/// MenuBarView — The dropdown UI shown when clicking the DGInf menu bar icon.
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
                Text("DGInf")
                    .font(.headline)
                Circle()
                    .fill(viewModel.coordinatorConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .help(viewModel.coordinatorConnected ? "Coordinator connected" : "Coordinator offline")
                Spacer()
                statusBadge
            }

            Divider()

            // Hardware + model info
            VStack(alignment: .leading, spacing: 6) {
                Text("\(viewModel.chipName) \u{00B7} \(viewModel.memoryGB) GB")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // Model with quick switcher
                Menu {
                    ForEach(viewModel.modelManager.availableModels, id: \.id) { model in
                        Button {
                            viewModel.currentModel = model.id
                            // Restart with new model if running
                            if viewModel.providerManager.isRunning {
                                viewModel.stop()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                    viewModel.start()
                                }
                            }
                        } label: {
                            HStack {
                                Text(model.id.components(separatedBy: "/").last ?? model.id)
                                if model.id == viewModel.currentModel {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if viewModel.modelManager.availableModels.isEmpty {
                        Text("No models downloaded")
                            .foregroundColor(.secondary)
                    }
                } label: {
                    HStack {
                        Text("Model:")
                            .foregroundColor(.secondary)
                        Text(viewModel.currentModel.components(separatedBy: "/").last ?? viewModel.currentModel)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                }
                .menuStyle(.borderlessButton)

                // Live status with animated throughput
                HStack {
                    Text("Status:")
                        .foregroundColor(.secondary)
                    statusText
                }
                .font(.subheadline)
                .animation(.smooth, value: viewModel.isServing)

                // Trust level
                HStack(spacing: 4) {
                    Text("Trust:")
                        .foregroundColor(.secondary)
                    Image(systemName: viewModel.securityManager.trustLevel.iconName)
                        .foregroundColor(trustColor)
                    Text(viewModel.securityManager.trustLevel.displayName)
                        .foregroundColor(trustColor)
                }
                .font(.subheadline)
            }

            // Trust warnings
            trustWarning

            Divider()

            // Stats
            if viewModel.requestsServed > 0 || viewModel.tokensGenerated > 0 {
                HStack {
                    Text("Today:")
                        .foregroundColor(.secondary)
                    Text("\(viewModel.requestsServed) requests")
                    Text("\u{00B7}")
                        .foregroundColor(.secondary)
                    Text(formatTokenCount(viewModel.tokensGenerated))
                }
                .font(.subheadline)
                .contentTransition(.numericText())
            }

            if !viewModel.earningsBalance.isEmpty {
                HStack {
                    Text("Earnings:")
                        .foregroundColor(.secondary)
                    Text(viewModel.earningsBalance)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
            }

            if viewModel.isOnline {
                HStack {
                    Text("Uptime:")
                        .foregroundColor(.secondary)
                    Text(formatUptime(viewModel.uptimeSeconds))
                        .monospacedDigit()
                }
                .font(.subheadline)
            }

            Divider()

            // On/Off toggle
            providerToggle

            // Sleep prevention
            if viewModel.providerManager.isRunning {
                Label("Sleep prevention active", systemImage: "bolt.shield")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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
                    .font(.caption)
                    .foregroundColor(.secondary)
                if viewModel.updateManager.updateAvailable {
                    Text("Update available")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Spacer()
            }

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Label("Quit DGInf", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
        .animation(.smooth, value: viewModel.isOnline)
        .animation(.smooth, value: viewModel.isPaused)
    }

    // MARK: - Components

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .modifier(GlassModifier(shape: .capsule, tint: statusColor.opacity(0.3)))
    }

    @ViewBuilder
    private var trustWarning: some View {
        if viewModel.securityManager.trustLevel == .none {
            Button(action: { openWindow(id: "setup") }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Complete setup for inference routing \u{2192}")
                }
                .font(.caption)
                .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        } else if viewModel.securityManager.trustLevel == .selfSigned {
            Button(action: { openWindow(id: "setup") }) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Enroll in MDM for hardware trust \u{2192}")
                }
                .font(.caption)
                .foregroundColor(.orange)
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
        }
        .toggleStyle(.switch)
        .padding(8)
        .modifier(GlassModifier(shape: .rect(cornerRadius: 10)))
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
            navButton("Wallet...", icon: "wallet.pass", window: "wallet")
            navButton("Benchmark...", icon: "gauge.with.dots.needle.bottom.50percent", window: "benchmark")
            navButton("Logs...", icon: "doc.text", window: "logs")
            if !viewModel.hasCompletedSetup {
                navButton("Setup Wizard...", icon: "wrench", window: "setup")
            }
            Button(action: { openSettings() }) {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)
            .modifier(InteractiveGlassModifier())
        }
    }

    private func navButton(_ title: String, icon: String, window: String) -> some View {
        Button(action: { openWindow(id: window) }) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.plain)
        .modifier(InteractiveGlassModifier())
    }

    private var statusText: some View {
        Group {
            if viewModel.isPaused {
                Text("Paused (user active)")
                    .foregroundColor(.yellow)
            } else if viewModel.isServing {
                HStack(spacing: 4) {
                    Text("Serving")
                        .foregroundColor(.green)
                    Text("\u{00B7}")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f tok/s", viewModel.tokensPerSecond))
                        .foregroundColor(.green)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            } else if viewModel.isOnline {
                Text("Ready")
                    .foregroundColor(.green)
            } else {
                Text("Stopped")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .green
        case .selfSigned: return .yellow
        case .none: return .red
        }
    }

    private var statusColor: Color {
        if viewModel.isPaused { return .yellow }
        if viewModel.isOnline { return .green }
        return .gray
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
