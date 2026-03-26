/// MenuBarView — The dropdown UI shown when clicking the DGInf menu bar icon.
///
/// Shows at-a-glance provider status with quick actions.

import SwiftUI

struct MenuBarView: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings: OpenSettingsAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with connectivity dot
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

            // Hardware info
            Text("\(viewModel.chipName) \u{00B7} \(viewModel.memoryGB) GB")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Model
            HStack {
                Text("Model:")
                    .foregroundColor(.secondary)
                Text(viewModel.currentModel)
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            // Status line
            HStack {
                Text("Status:")
                    .foregroundColor(.secondary)
                statusText
            }
            .font(.subheadline)

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

            // Warning if not hardware trusted
            if viewModel.securityManager.trustLevel != .hardware && viewModel.hasCompletedSetup {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Setup needed for inference routing")
                        .foregroundColor(.orange)
                }
                .font(.caption)
            }

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
            }

            // Earnings
            if !viewModel.earningsBalance.isEmpty {
                HStack {
                    Text("Earnings:")
                        .foregroundColor(.secondary)
                    Text(viewModel.earningsBalance)
                        .fontWeight(.medium)
                }
                .font(.subheadline)
            }

            // Uptime
            if viewModel.isOnline {
                HStack {
                    Text("Uptime:")
                        .foregroundColor(.secondary)
                    Text(formatUptime(viewModel.uptimeSeconds))
                }
                .font(.subheadline)
            }

            Divider()

            // Actions
            if viewModel.isOnline {
                Button(action: { viewModel.stop() }) {
                    Label("Stop Provider", systemImage: "stop.fill")
                }
                .buttonStyle(.plain)
            } else {
                Button(action: { viewModel.start() }) {
                    Label("Start Provider", systemImage: "play.fill")
                }
                .buttonStyle(.plain)
            }

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

            Button(action: { openWindow(id: "dashboard") }) {
                Label("Dashboard...", systemImage: "chart.bar")
            }
            .buttonStyle(.plain)

            Button(action: { openWindow(id: "wallet") }) {
                Label("Wallet...", systemImage: "wallet.pass")
            }
            .buttonStyle(.plain)

            Button(action: { openWindow(id: "benchmark") }) {
                Label("Benchmark...", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            .buttonStyle(.plain)

            Button(action: { openWindow(id: "logs") }) {
                Label("Logs...", systemImage: "doc.text")
            }
            .buttonStyle(.plain)

            if !viewModel.hasCompletedSetup {
                Button(action: { openWindow(id: "setup") }) {
                    Label("Setup Wizard...", systemImage: "wrench")
                }
                .buttonStyle(.plain)
            }

            Button(action: { openSettings() }) {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Divider()

            // Version + update
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

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit DGInf", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Subviews

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

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
