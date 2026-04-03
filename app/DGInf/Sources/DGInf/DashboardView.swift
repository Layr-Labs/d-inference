/// DashboardView — Detailed statistics window for the DGInf provider.
///
/// Shows hardware info, session stats, provider status, and live
/// security/trust posture from SecurityManager.
/// Uses a modern card-based layout with SF Symbol accents.

import SwiftUI

struct DashboardView: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                hardwareGrid
                statusCard
                statsRow
                trustCard
                actionBar
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 14) {
            // App icon area
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(statusGradient)
                    .frame(width: 52, height: 52)
                Image(systemName: statusIconName)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: viewModel.isServing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DGInf Provider")
                    .font(.title3)
                    .fontWeight(.bold)
                HStack(spacing: 6) {
                    Text(providerStatusText)
                        .font(.subheadline)
                        .foregroundStyle(statusAccentColor)
                        .fontWeight(.medium)
                    Text("v\(viewModel.updateManager.currentVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Status pill
            statusPill
        }
        .cardStyle()
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusAccentColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusAccentColor.opacity(0.5), radius: 4)
            Text(statusLabel)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(statusAccentColor.opacity(0.12), in: Capsule())
    }

    // MARK: - Hardware Grid

    private var hardwareGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 10) {
            metricCard(
                icon: "cpu",
                iconColor: .blue,
                label: "Chip",
                value: viewModel.chipName
                    .replacingOccurrences(of: "Apple ", with: "")
            )
            metricCard(
                icon: "memorychip",
                iconColor: .purple,
                label: "Memory",
                value: "\(viewModel.memoryGB) GB",
                detail: "Unified"
            )
            metricCard(
                icon: "gpu",
                iconColor: .orange,
                label: "GPU Cores",
                value: viewModel.gpuCores > 0 ? "\(viewModel.gpuCores)" : "--"
            )
            metricCard(
                icon: "arrow.left.arrow.right",
                iconColor: .teal,
                label: "Bandwidth",
                value: viewModel.memoryBandwidthGBs > 0 ? "\(viewModel.memoryBandwidthGBs)" : "--",
                detail: "GB/s"
            )
        }
    }

    private func metricCard(
        icon: String,
        iconColor: Color,
        label: String,
        value: String,
        detail: String? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .fontWeight(.medium)
                .foregroundStyle(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .cardStyle(padding: 10)
    }

    // MARK: - Provider Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Provider", systemImage: "server.rack")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(viewModel.currentModel.components(separatedBy: "/").last ?? viewModel.currentModel)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }

                Spacer()

                Divider()
                    .frame(height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Coordinator")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(viewModel.coordinatorConnected ? Color.green : Color.red.opacity(0.7))
                            .frame(width: 7, height: 7)
                        Text(viewModel.coordinatorConnected ? "Connected" : "Disconnected")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(viewModel.coordinatorConnected ? .primary : .secondary)
                    }
                }

                if viewModel.isServing {
                    Divider()
                        .frame(height: 32)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Throughput")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(statusAccentColor.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 10) {
            statCard(
                label: "Uptime",
                value: formatUptime(viewModel.uptimeSeconds),
                icon: "clock",
                color: .blue
            )
            statCard(
                label: "Requests",
                value: "\(viewModel.requestsServed)",
                icon: "arrow.up.arrow.down",
                color: .green
            )
            statCard(
                label: "Tokens",
                value: formatTokenCount(viewModel.tokensGenerated),
                icon: "text.word.spacing",
                color: .orange
            )
            if !viewModel.earningsBalance.isEmpty {
                statCard(
                    label: "Earnings",
                    value: viewModel.earningsBalance,
                    icon: "dollarsign.circle",
                    color: .green
                )
            }
        }
    }

    private func statCard(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .cardStyle(padding: 12)
    }

    // MARK: - Trust & Attestation

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Trust & Attestation", systemImage: "shield.checkered")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                trustBadge
                if viewModel.securityManager.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await viewModel.securityManager.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], spacing: 8) {
                securityChip("Enclave", viewModel.securityManager.secureEnclaveAvailable)
                securityChip("SIP", viewModel.securityManager.sipEnabled)
                securityChip("Secure Boot", viewModel.securityManager.secureBootEnabled)
                securityChip("MDM", viewModel.securityManager.mdmEnrolled)
                securityChip("Node Key", viewModel.securityManager.nodeKeyExists)
                securityChip("Binary", viewModel.securityManager.binaryFound)
            }
        }
        .cardStyle()
    }

    private var trustBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: viewModel.securityManager.trustLevel.iconName)
                .font(.caption2)
            Text(viewModel.securityManager.trustLevel.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(trustColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(trustColor.opacity(0.1), in: Capsule())
    }

    private func securityChip(_ label: String, _ enabled: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .font(.caption2)
                .foregroundStyle(enabled ? .green : .red.opacity(0.6))
            Text(label)
                .font(.caption)
                .foregroundStyle(enabled ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            (enabled ? Color.green : Color.red).opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            actionButton("Diagnostics", icon: "stethoscope", window: "doctor")
            actionButton("Logs", icon: "doc.text", window: "logs")
            actionButton("Benchmark", icon: "gauge.with.dots.needle.bottom.50percent", window: "benchmark")
            actionButton("Wallet", icon: "wallet.pass", window: "wallet")

            if !viewModel.hasCompletedSetup {
                Button { openWindow(id: "setup") } label: {
                    Label("Setup", systemImage: "wrench")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func actionButton(_ title: String, icon: String, window: String) -> some View {
        Button { openWindow(id: window) } label: {
            Label(title, systemImage: icon)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Helpers

    private var statusIconName: String {
        if viewModel.isPaused { return "pause.fill" }
        if viewModel.isServing { return "bolt.fill" }
        if viewModel.isOnline { return "checkmark" }
        return "power"
    }

    private var statusGradient: LinearGradient {
        LinearGradient(
            colors: statusGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var statusGradientColors: [Color] {
        if viewModel.isPaused { return [.yellow, .orange] }
        if viewModel.isServing { return [.green, .mint] }
        if viewModel.isOnline { return [.blue, .cyan] }
        return [.gray, .gray.opacity(0.7)]
    }

    private var statusAccentColor: Color {
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
        if viewModel.isPaused { return "Paused" }
        if viewModel.isServing { return "Serving inference" }
        if viewModel.isOnline { return "Online, waiting for requests" }
        return "Offline"
    }

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .green
        case .selfSigned: return .yellow
        case .none: return .red
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - Card Style Modifier

private struct CardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

extension View {
    fileprivate func cardStyle(padding: CGFloat = 14) -> some View {
        modifier(CardModifier(padding: padding))
    }
}
