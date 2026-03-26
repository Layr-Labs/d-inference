/// DashboardView — Detailed statistics window for the DGInf provider.
///
/// Shows hardware info, session stats, provider status, and live
/// security/trust posture from SecurityManager.

import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack {
                    VStack(alignment: .leading) {
                        Text("DGInf Provider Dashboard")
                            .font(.title2)
                            .fontWeight(.bold)
                        HStack(spacing: 4) {
                            Text("Decentralized Private Inference")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("v\(viewModel.updateManager.currentVersion)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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

                        HStack {
                            Text("Coordinator")
                                .foregroundColor(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Circle()
                                .fill(viewModel.coordinatorConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.coordinatorConnected ? "Connected" : "Disconnected")
                                .foregroundColor(viewModel.coordinatorConnected ? .green : .red)
                        }

                        if viewModel.isServing {
                            infoRow("Throughput", String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                        }
                    }
                }

                // Session stats
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeader("Session Statistics")
                        infoRow("Uptime", formatUptime(viewModel.uptimeSeconds))
                        infoRow("Requests Served", "\(viewModel.requestsServed)")
                        infoRow("Tokens Generated", formatTokenCount(viewModel.tokensGenerated))

                        if !viewModel.earningsBalance.isEmpty {
                            infoRow("Earnings", viewModel.earningsBalance)
                        }
                    }
                }

                // Trust & Security section (live data from SecurityManager)
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            sectionHeader("Trust & Attestation")
                            Spacer()
                            if viewModel.securityManager.isChecking {
                                ProgressView().controlSize(.small)
                            }
                            Button {
                                Task { await viewModel.securityManager.refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                        }

                        // Trust level badge
                        HStack {
                            Text("Trust Level")
                                .foregroundColor(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Image(systemName: viewModel.securityManager.trustLevel.iconName)
                                .foregroundColor(trustColor)
                            Text(viewModel.securityManager.trustLevel.displayName)
                                .foregroundColor(trustColor)
                                .fontWeight(.medium)
                        }

                        securityRow("Secure Enclave", viewModel.securityManager.secureEnclaveAvailable)
                        securityRow("SIP", viewModel.securityManager.sipEnabled)
                        securityRow("Secure Boot", viewModel.securityManager.secureBootEnabled)
                        securityRow("MDM Enrolled", viewModel.securityManager.mdmEnrolled)
                        securityRow("Node Key", viewModel.securityManager.nodeKeyExists)
                    }
                }

                // Action buttons
                HStack(spacing: 12) {
                    Button {
                        openWindow(id: "doctor")
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openWindow(id: "logs")
                    } label: {
                        Label("Logs", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openWindow(id: "benchmark")
                    } label: {
                        Label("Benchmark", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openWindow(id: "wallet")
                    } label: {
                        Label("Wallet", systemImage: "wallet.pass")
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.hasCompletedSetup {
                        Button {
                            openWindow(id: "setup")
                        } label: {
                            Label("Setup", systemImage: "wrench")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 550, minHeight: 600)
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    // MARK: - Subviews

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

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .green
        case .selfSigned: return .yellow
        case .none: return .red
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.bottom, 4)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
        }
        .font(.body)
    }

    private func securityRow(_ label: String, _ enabled: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(enabled ? .green : .red)
            Text(enabled ? "Yes" : "No")
                .foregroundColor(enabled ? .primary : .red)
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m \(secs)s" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}
