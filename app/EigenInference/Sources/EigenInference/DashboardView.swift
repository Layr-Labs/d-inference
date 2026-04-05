/// DashboardView — Provider dashboard with warm, vibrant card design.

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
        .frame(minWidth: 540, idealWidth: 580, minHeight: 600)
        .background(Color.warmBg)
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(statusGradient)
                    .frame(width: 56, height: 56)
                    .shadow(color: statusAccentColor.opacity(0.3), radius: 8, y: 4)
                Image(systemName: statusIconName)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: viewModel.isServing)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text("Eigen")
                        .font(.display(24))
                        .foregroundStyle(Color.warmInk)
                    Text("Inference")
                        .font(.display(24))
                        .foregroundStyle(Color.coral)
                }
                HStack(spacing: 6) {
                    Text(providerStatusText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusAccentColor)
                    Text("v\(viewModel.updateManager.currentVersion)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.warmInkFaint)
                }
            }

            Spacer()

            WarmBadge(text: statusLabel, color: statusAccentColor,
                      icon: statusLabel == "Serving" ? "bolt.fill" : nil)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.warmBgSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(statusAccentColor.opacity(0.25), lineWidth: 2)
                )
        )
        .shadow(color: statusAccentColor.opacity(0.1), radius: 8, y: 4)
    }

    // MARK: - Hardware Grid

    private var hardwareGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ], spacing: 12) {
            hwCard(
                icon: "cpu", color: .blueAccent,
                label: "Chip",
                value: viewModel.chipName.replacingOccurrences(of: "Apple ", with: ""),
                rotation: -0.5
            )
            hwCard(
                icon: "memorychip", color: .purpleAccent,
                label: "Memory",
                value: "\(viewModel.memoryGB) GB", detail: "Unified",
                rotation: 0.3
            )
            hwCard(
                icon: "gpu", color: .gold,
                label: "GPU Cores",
                value: viewModel.gpuCores > 0 ? "\(viewModel.gpuCores)" : "--",
                rotation: 0.4
            )
            hwCard(
                icon: "arrow.left.arrow.right", color: .tealAccent,
                label: "Bandwidth",
                value: viewModel.memoryBandwidthGBs > 0 ? "\(viewModel.memoryBandwidthGBs)" : "--",
                detail: "GB/s",
                rotation: -0.3
            )
        }
    }

    private func hwCard(
        icon: String, color: Color,
        label: String, value: String,
        detail: String? = nil,
        rotation: Double = 0
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: color.opacity(0.3), radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.warmInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.warmInkFaint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(color.opacity(0.2), lineWidth: 2)
                )
        )
        .rotationEffect(.degrees(rotation))
    }

    // MARK: - Provider Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.coral, in: RoundedRectangle(cornerRadius: 8))
                Text("Provider")
                    .font(.displaySmall)
                    .foregroundStyle(Color.warmInk)
                Spacer()
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MODEL")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.warmInkFaint)
                    Text(viewModel.currentModel.components(separatedBy: "/").last ?? viewModel.currentModel)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.warmInk)
                        .lineLimit(1)
                }

                Spacer()

                Divider().frame(height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text("COORDINATOR")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.warmInkFaint)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(viewModel.coordinatorConnected ? Color.tealAccent : Color.warmError)
                            .frame(width: 8, height: 8)
                            .shadow(color: (viewModel.coordinatorConnected ? Color.tealAccent : Color.warmError).opacity(0.5), radius: 4)
                        Text(viewModel.coordinatorConnected ? "Connected" : "Disconnected")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(viewModel.coordinatorConnected ? Color.tealAccent : Color.warmError)
                    }
                }

                if viewModel.isServing {
                    Divider().frame(height: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("THROUGHPUT")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.warmInkFaint)
                        Text(String(format: "%.1f tok/s", viewModel.tokensPerSecond))
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.tealAccent)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.coral.opacity(0.2), lineWidth: 2)
                )
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 12) {
            liveStatCard(
                icon: "clock", color: .blueAccent,
                label: "Uptime",
                value: formatUptime(viewModel.uptimeSeconds)
            )
            liveStatCard(
                icon: "arrow.up.arrow.down", color: .tealAccent,
                label: "Requests",
                value: "\(viewModel.requestsServed)"
            )
            liveStatCard(
                icon: "text.word.spacing", color: .gold,
                label: "Tokens",
                value: formatTokenCount(viewModel.tokensGenerated)
            )
            if !viewModel.earningsBalance.isEmpty {
                liveStatCard(
                    icon: "dollarsign.circle", color: .coral,
                    label: "Earnings",
                    value: viewModel.earningsBalance
                )
            }
        }
    }

    private func liveStatCard(icon: String, color: Color, label: String, value: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color, in: Circle())
                .shadow(color: color.opacity(0.3), radius: 4, y: 2)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.warmInk)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(color.opacity(0.15), lineWidth: 1.5)
                )
        )
    }

    // MARK: - Trust & Attestation

    private var trustCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.tealAccent, in: RoundedRectangle(cornerRadius: 8))
                Text("Trust & Attestation")
                    .font(.displaySmall)
                    .foregroundStyle(Color.warmInk)
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
                        .foregroundStyle(Color.warmInkFaint)
                }
                .buttonStyle(.borderless)
                .pointerOnHover()
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
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.tealAccent.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.tealAccent.opacity(0.2), lineWidth: 2)
                )
        )
    }

    private var trustBadge: some View {
        WarmBadge(
            text: viewModel.securityManager.trustLevel.displayName,
            color: trustColor,
            icon: viewModel.securityManager.trustLevel.iconName
        )
    }

    private func securityChip(_ label: String, _ enabled: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? Color.tealAccent : Color.warmError)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(enabled ? Color.warmInk : Color.warmInkLight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(enabled ? Color.tealAccent.opacity(0.08) : Color.warmError.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder((enabled ? Color.tealAccent : Color.warmError).opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 10) {
            actionButton("Diagnostics", icon: "stethoscope", color: .blueAccent, window: "doctor")
            actionButton("Logs", icon: "doc.text", color: .purpleAccent, window: "logs")

            if !viewModel.hasCompletedSetup {
                Button { openWindow(id: "setup") } label: {
                    Label("Setup", systemImage: "wrench")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .buttonStyle(WarmButtonStyle(.coral))
                .pointerOnHover()
            }
        }
    }

    private func actionButton(_ title: String, icon: String, color: Color, window: String) -> some View {
        Button { openWindow(id: window) } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .buttonStyle(WarmButtonStyle(color, filled: false))
        .pointerOnHover()
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
        if viewModel.isPaused { return [.gold, .goldLight] }
        if viewModel.isServing { return [.coral, .gold] }
        if viewModel.isOnline { return [.coral, .coralLight] }
        return [.warmInkFaint, .warmInkFaint.opacity(0.7)]
    }

    private var statusAccentColor: Color {
        if viewModel.isPaused { return .gold }
        if viewModel.isServing { return .tealAccent }
        if viewModel.isOnline { return .blueAccent }
        return .warmInkFaint
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
        if viewModel.isOnline { return "Online, waiting" }
        return "Offline"
    }

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .tealAccent
        case .selfSigned: return .gold
        case .none: return .warmError
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
