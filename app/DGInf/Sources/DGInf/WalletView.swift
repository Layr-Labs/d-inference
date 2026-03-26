/// WalletView — Wallet address display and earnings overview.
///
/// Shows the provider's Ethereum-compatible wallet address (stored in
/// macOS Keychain) and earnings from serving inference requests.

import SwiftUI

struct WalletView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Wallet & Earnings")
                    .font(.title2)
                    .fontWeight(.bold)

                // Wallet section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Wallet", systemImage: "wallet.pass")
                            .font(.headline)

                        if viewModel.walletAddress.isEmpty {
                            HStack {
                                Text("No wallet configured")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Create Wallet") {
                                    Task { await viewModel.refreshWallet() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Address")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Text(viewModel.walletAddress)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(viewModel.walletAddress, forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Copy address")
                                }

                                Text("Stored in macOS Keychain")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }

                // Earnings section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Earnings", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.headline)
                            Spacer()
                            Button {
                                Task { await viewModel.refreshEarnings() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Refresh earnings")
                        }

                        if viewModel.earningsBalance.isEmpty {
                            Text("Connect to the coordinator to view earnings.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            HStack(spacing: 24) {
                                VStack(alignment: .leading) {
                                    Text("Balance")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(viewModel.earningsBalance)
                                        .font(.title2)
                                        .fontWeight(.bold)
                                }
                                VStack(alignment: .leading) {
                                    Text("Requests Served")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(viewModel.requestsServed)")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                }
                                VStack(alignment: .leading) {
                                    Text("Tokens Generated")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(formatTokenCount(viewModel.tokensGenerated))
                                        .font(.title2)
                                        .fontWeight(.bold)
                                }
                            }
                        }
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(20)
        }
        .frame(minWidth: 500, minHeight: 350)
        .task {
            await viewModel.refreshWallet()
            await viewModel.refreshEarnings()
        }
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
