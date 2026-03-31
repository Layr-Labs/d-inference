/// WalletView — Earnings overview and payout account.
///
/// Shows earnings in USD, session statistics, and account ID
/// for receiving payouts. No crypto terminology exposed.

import SwiftUI

struct WalletView: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var copiedAccountId = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Earnings")
                    .font(.title2)
                    .fontWeight(.bold)

                // Balance card
                earningsCard

                // Stats row
                statsRow

                // Account section
                accountSection

                Spacer()
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 400)
        .task {
            await viewModel.refreshWallet()
            await viewModel.refreshEarnings()
        }
    }

    // MARK: - Earnings Card

    @ViewBuilder
    private var earningsCard: some View {
        if #available(macOS 26.0, *) {
            earningsCardContent
                .padding(20)
                .glassEffect(.regular.tint(.green.opacity(0.1)), in: .rect(cornerRadius: 16))
        } else {
            GroupBox {
                earningsCardContent
                    .padding(4)
            }
        }
    }

    private var earningsCardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Balance", systemImage: "dollarsign.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await viewModel.refreshEarnings() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh balance")
            }

            if viewModel.earningsBalance.isEmpty {
                Text("$0.00")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text("Start serving to earn")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(formatAsDollars(viewModel.earningsBalance))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                    .contentTransition(.numericText())
            }
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 16) {
            statCard("Requests", value: "\(viewModel.requestsServed)", icon: "arrow.up.arrow.down")
            statCard("Tokens", value: formatTokenCount(viewModel.tokensGenerated), icon: "text.word.spacing")
            statCard("Uptime", value: formatUptime(viewModel.uptimeSeconds), icon: "clock")
        }
    }

    @ViewBuilder
    private func statCard(_ title: String, value: String, icon: String) -> some View {
        if #available(macOS 26.0, *) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            GroupBox {
                VStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(.accentColor)
                    Text(value)
                        .font(.title3)
                        .fontWeight(.bold)
                        .monospacedDigit()
                    Text(title)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private var accountSection: some View {
        if #available(macOS 26.0, *) {
            accountContent
                .padding(12)
                .glassEffect(in: .rect(cornerRadius: 12))
        } else {
            GroupBox {
                accountContent
                    .padding(4)
            }
        }
    }

    private var accountContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Payout Account", systemImage: "person.crop.circle")
                .font(.headline)

            if viewModel.walletAddress.isEmpty {
                HStack {
                    Text("No account configured")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Create Account") {
                        Task { await viewModel.refreshWallet() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Account ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(viewModel.walletAddress)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(viewModel.walletAddress, forType: .string)
                        copiedAccountId = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copiedAccountId = false
                        }
                    } label: {
                        if copiedAccountId {
                            Label("Copied", systemImage: "checkmark")
                                .foregroundColor(.green)
                        } else {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .animation(.smooth, value: copiedAccountId)
                }

                Text("Secured by macOS Keychain")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Formatting

    private func formatAsDollars(_ raw: String) -> String {
        // If the raw string already has a $ sign, return as-is
        if raw.contains("$") { return raw }
        // Try to parse as number and format
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        if let amount = Double(cleaned) {
            return String(format: "$%.2f", amount)
        }
        // Fallback: prefix with $
        return "$\(cleaned)"
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }

    private func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
