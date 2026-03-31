/// DashboardView — Detailed statistics window for the DGInf provider.
///
/// Shows hardware info, session stats, provider status, and live
/// security/trust posture from SecurityManager.
/// Uses Liquid Glass on macOS 26+, GroupBox on older versions.

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

                // Hardware
                glassSection("Hardware") {
                    infoRow("Chip", viewModel.chipName)
                    infoRow("Unified Memory", "\(viewModel.memoryGB) GB")
                    infoRow("GPU Cores", viewModel.gpuCores > 0 ? "\(viewModel.gpuCores)" : "Detecting...")
                    infoRow("Memory Bandwidth", viewModel.memoryBandwidthGBs > 0 ? "\(viewModel.memoryBandwidthGBs) GB/s" : "Detecting...")
                }

                // Provider Status
                glassSection("Provider Status") {
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
                        HStack {
                            Text("Throughput")
                                .foregroundColor(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Text(String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                                .monospacedDigit()
                                .foregroundStyle(.green)
                                .fontWeight(.medium)
                                .contentTransition(.numericText())
                        }
                        .font(.body)
                    }
                }

                // Session Stats
                glassSection("Session Statistics") {
                    infoRow("Uptime", formatUptime(viewModel.uptimeSeconds))
                    HStack {
                        Text("Requests Served")
                            .foregroundColor(.secondary)
                            .frame(width: 140, alignment: .leading)
                        Text("\(viewModel.requestsServed)")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.body)
                    HStack {
                        Text("Tokens Generated")
                            .foregroundColor(.secondary)
                            .frame(width: 140, alignment: .leading)
                        Text(formatTokenCount(viewModel.tokensGenerated))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    .font(.body)

                    if !viewModel.earningsBalance.isEmpty {
                        HStack {
                            Text("Earnings")
                                .foregroundColor(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Text(viewModel.earningsBalance)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                        }
                        .font(.body)
                    }
                }

                // Trust & Security
                trustSection

                // Action buttons
                HStack(spacing: 12) {
                    actionButton("Diagnostics", icon: "stethoscope", window: "doctor")
                    actionButton("Logs", icon: "doc.text", window: "logs")
                    actionButton("Benchmark", icon: "gauge.with.dots.needle.bottom.50percent", window: "benchmark")
                    actionButton("Wallet", icon: "wallet.pass", window: "wallet")

                    if !viewModel.hasCompletedSetup {
                        Button { openWindow(id: "setup") } label: {
                            Label("Setup", systemImage: "wrench")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            .animation(.smooth, value: viewModel.requestsServed)
            .animation(.smooth, value: viewModel.tokensGenerated)
        }
        .frame(minWidth: 550, minHeight: 600)
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    // MARK: - Glass Section Builder

    @ViewBuilder
    private func glassSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(macOS 26.0, *) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title)
                content()
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    sectionHeader(title)
                    content()
                }
            }
        }
    }

    @ViewBuilder
    private var trustSection: some View {
        if #available(macOS 26.0, *) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionHeader("Trust & Attestation")
                    Spacer()
                    refreshButton
                }
                trustContent
            }
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        sectionHeader("Trust & Attestation")
                        Spacer()
                        refreshButton
                    }
                    trustContent
                }
            }
        }
    }

    private var refreshButton: some View {
        HStack(spacing: 8) {
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
    }

    @ViewBuilder
    private var trustContent: some View {
        HStack {
            Text("Trust Level")
                .foregroundColor(.secondary)
                .frame(width: 140, alignment: .leading)
            Image(systemName: viewModel.securityManager.trustLevel.iconName)
                .foregroundColor(trustColor)
                .symbolEffect(.bounce, value: viewModel.securityManager.trustLevel.displayName)
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

    private func actionButton(_ title: String, icon: String, window: String) -> some View {
        Button { openWindow(id: window) } label: {
            Label(title, systemImage: icon)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Subviews

    private var statusIndicator: some View {
        VStack {
            Circle()
                .fill(statusColor)
                .frame(width: 16, height: 16)
                .shadow(color: statusColor.opacity(0.5), radius: 4)
            Text(statusLabel)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .animation(.easeInOut(duration: 0.5), value: statusLabel)
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
                .symbolEffect(.bounce, value: enabled)
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
