/// MenuBarView — The dropdown UI shown when clicking the DGInf menu bar icon.
///
/// Displays at-a-glance provider status: hardware info, current model,
/// throughput, and session stats. Provides quick actions to start/stop
/// the provider, open the dashboard, and access settings.
///
/// Layout:
///   ┌──────────────────────────────────────┐
///   │  DGInf                    ● Online   │
///   │                                      │
///   │  Apple M3 Max · 64 GB               │
///   │  Model: Qwen3.5-4B                  │
///   │  Status: Serving · 94 tok/s          │
///   │                                      │
///   │  Today: 142 requests · 48.2K tokens │
///   │                                      │
///   │  ─────────────────────────────────── │
///   │  Start / Pause                       │
///   │  Dashboard...                        │
///   │  Settings...                         │
///   │  ─────────────────────────────────── │
///   │  Quit DGInf                          │
///   └──────────────────────────────────────┘

import SwiftUI

/// The menu bar dropdown content view.
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

                Divider()
            }

            // Uptime
            if viewModel.isOnline {
                HStack {
                    Text("Uptime:")
                        .foregroundColor(.secondary)
                    Text(formatUptime(viewModel.uptimeSeconds))
                }
                .font(.subheadline)

                Divider()
            }

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

            Button(action: { openSettings() }) {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Divider()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit DGInf", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Subviews

    /// The colored status badge (green dot = online, gray = offline, yellow = paused).
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

    /// Status text showing serving state and throughput.
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

    // MARK: - Formatting

    /// Format a token count for display (e.g., 48200 -> "48.2K").
    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK tokens", Double(count) / 1_000)
        }
        return "\(count) tokens"
    }

    /// Format uptime seconds into a human-readable string (e.g., "2h 34m").
    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
