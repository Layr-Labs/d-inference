/// SettingsView — Configuration window for the DGInf provider.
///
/// Tabs:
///   - General: Coordinator URL, API key, auto-start on login
///   - Availability: Idle timeout, schedule
///   - Model: Full model catalog with fit indicators and download/remove
///   - Security: Security posture overview

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        TabView {
            GeneralTab(viewModel: viewModel)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AvailabilityTab(viewModel: viewModel)
                .tabItem {
                    Label("Availability", systemImage: "clock")
                }

            ModelCatalogView(viewModel: viewModel)
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }

            SecurityTab(viewModel: viewModel)
                .tabItem {
                    Label("Security", systemImage: "shield")
                }
        }
        .frame(width: 550, height: 420)
    }
}

// MARK: - General Tab

private struct GeneralTab: View {
    @ObservedObject var viewModel: StatusViewModel

    var body: some View {
        Form {
            Section {
                TextField("Coordinator URL:", text: $viewModel.coordinatorURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key:", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Connection")
                    .font(.headline)
            }

            Section {
                Toggle("Start DGInf when you log in", isOn: $viewModel.autoStart)

                HStack {
                    Text("LaunchAgent:")
                        .foregroundColor(.secondary)
                    Text(LaunchAgentManager.isInstalled ? "Installed" : "Not installed")
                        .font(.caption)
                        .foregroundColor(LaunchAgentManager.isInstalled ? .green : .secondary)
                }
            } header: {
                Text("Startup")
                    .font(.headline)
            }

            Section {
                HStack {
                    Text("Provider Binary:")
                        .foregroundColor(.secondary)
                    if let path = CLIRunner.resolveBinaryPath() {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not found")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                HStack {
                    Text("Version:")
                        .foregroundColor(.secondary)
                    Text("v\(viewModel.updateManager.currentVersion)")
                        .font(.caption)
                    if viewModel.updateManager.updateAvailable {
                        Text("(update available)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            } header: {
                Text("Status")
                    .font(.headline)
            }
        }
        .padding()
    }
}

// MARK: - Availability Tab

private struct AvailabilityTab: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var selectedTimeout: TimeInterval = 300

    var body: some View {
        Form {
            Section {
                Picker("Pause when user is active for:", selection: $selectedTimeout) {
                    Text("1 minute").tag(TimeInterval(60))
                    Text("5 minutes").tag(TimeInterval(300))
                    Text("15 minutes").tag(TimeInterval(900))
                    Text("30 minutes").tag(TimeInterval(1800))
                    Text("Never pause").tag(TimeInterval(0))
                }
                .onChange(of: selectedTimeout) { _, newValue in
                    viewModel.idleTimeoutSeconds = newValue
                }

                Text("When you're using your Mac, DGInf will pause inference to keep your machine responsive. It resumes automatically when you step away.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Idle Detection")
                    .font(.headline)
            }
        }
        .padding()
        .onAppear {
            selectedTimeout = viewModel.idleTimeoutSeconds
        }
    }
}

// MARK: - Security Tab

private struct SecurityTab: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Security Posture")
                    .font(.headline)
                Spacer()
                if viewModel.securityManager.isChecking {
                    ProgressView().controlSize(.small)
                }
                Button("Refresh") {
                    Task { await viewModel.securityManager.refresh() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Trust level
            if #available(macOS 26.0, *) {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.securityManager.trustLevel.iconName)
                        .font(.title2)
                        .foregroundColor(trustColor)
                    VStack(alignment: .leading) {
                        Text(viewModel.securityManager.trustLevel.displayName)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(trustColor)
                        Text(trustDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(12)
                .glassEffect(.regular.tint(trustColor.opacity(0.15)), in: .rect(cornerRadius: 12))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.securityManager.trustLevel.iconName)
                        .font(.title2)
                        .foregroundColor(trustColor)
                    VStack(alignment: .leading) {
                        Text(viewModel.securityManager.trustLevel.displayName)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(trustColor)
                        Text(trustDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                checkRow("SIP", viewModel.securityManager.sipEnabled)
                checkRow("Secure Enclave", viewModel.securityManager.secureEnclaveAvailable)
                checkRow("Secure Boot", viewModel.securityManager.secureBootEnabled)
                checkRow("MDM Enrolled", viewModel.securityManager.mdmEnrolled)
                checkRow("Node Key", viewModel.securityManager.nodeKeyExists)
                checkRow("Provider Binary", viewModel.securityManager.binaryFound)
            }

            Spacer()

            Button {
                openWindow(id: "doctor")
            } label: {
                Label("Run Full Diagnostics...", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    private var trustColor: Color {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return .green
        case .selfSigned: return .yellow
        case .none: return .red
        }
    }

    private var trustDescription: String {
        switch viewModel.securityManager.trustLevel {
        case .hardware: return "All security checks pass. Your provider will receive inference requests."
        case .selfSigned: return "Partial verification. Complete MDM enrollment for hardware trust."
        case .none: return "Not verified. Complete the setup wizard to enable inference routing."
        }
    }

    private func checkRow(_ label: String, _ enabled: Bool) -> some View {
        HStack {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(enabled ? .green : .red)
            Text(label)
            Spacer()
            Text(enabled ? "OK" : "Missing")
                .font(.caption)
                .foregroundColor(enabled ? .secondary : .red)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .modifier(GlassRowModifier())
    }

    private struct GlassRowModifier: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *) {
                content.glassEffect(in: .rect(cornerRadius: 8))
            } else {
                content
            }
        }
    }
}
