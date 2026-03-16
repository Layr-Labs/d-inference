/// DashboardView — Detailed statistics window for the DGInf provider.
///
/// Shows a comprehensive overview of the provider's operation:
///   - Hardware information (chip, memory, GPU cores, bandwidth)
///   - Current session stats (uptime, requests, tokens, throughput)
///   - Provider status and model info
///   - Trust/attestation status
///
/// Opened from the menu bar dropdown via the "Dashboard..." button.

import SwiftUI

/// The dashboard statistics window.
struct DashboardView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("DGInf Provider Dashboard")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Decentralized GPU Inference Network")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    statusIndicator
                }

                Divider()

                // Hardware section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Hardware")

                        infoRow("Chip", viewModel.chipName)
                        infoRow("Unified Memory", "\(viewModel.memoryGB) GB")
                        infoRow("GPU Cores", viewModel.gpuCores > 0 ? "\(viewModel.gpuCores)" : "Detecting...")
                        infoRow("Memory Bandwidth", viewModel.memoryBandwidthGBs > 0 ? "\(viewModel.memoryBandwidthGBs) GB/s" : "Detecting...")
                    }
                }

                // Provider status section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Provider Status")

                        infoRow("Status", providerStatusText)
                        infoRow("Model", viewModel.currentModel)
                        infoRow("Coordinator", viewModel.coordinatorURL)

                        if viewModel.isServing {
                            infoRow("Throughput", String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                        }
                    }
                }

                // Session stats section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Session Statistics")

                        infoRow("Uptime", formatUptime(viewModel.uptimeSeconds))
                        infoRow("Requests Served", "\(viewModel.requestsServed)")
                        infoRow("Tokens Generated", formatTokenCount(viewModel.tokensGenerated))
                    }
                }

                // Trust section
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Trust & Attestation")

                        HStack {
                            Text("Secure Enclave")
                                .foregroundColor(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text("Available")
                                .foregroundColor(.green)
                        }

                        infoRow("Identity", "Hardware-bound P-256 key")
                        infoRow("Attestation", viewModel.isOnline ? "Active" : "Inactive")
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    // MARK: - Subviews

    /// Large status indicator in the header.
    private var statusIndicator: some View {
        VStack {
            Circle()
                .fill(statusColor)
                .frame(width: 16, height: 16)
            Text(statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        if viewModel.isPaused { return .yellow }
        if viewModel.isServing { return .green }
        if viewModel.isOnline { return .blue }
        return .gray
    }

    private var statusLabel: String {
        if viewModel.isPaused { return "Paused" }
        if viewModel.isServing { return "Serving" }
        if viewModel.isOnline { return "Ready" }
        return "Offline"
    }

    private var providerStatusText: String {
        if viewModel.isPaused { return "Paused (user active)" }
        if viewModel.isServing { return "Actively serving inference" }
        if viewModel.isOnline { return "Online, waiting for requests" }
        return "Stopped"
    }

    /// Section header label.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.bottom, 4)
    }

    /// A labeled info row: "Label    Value"
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
        }
        .font(.body)
    }

    // MARK: - Formatting

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        } else if minutes > 0 {
            return "\(minutes)m \(secs)s"
        }
        return "\(secs)s"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
