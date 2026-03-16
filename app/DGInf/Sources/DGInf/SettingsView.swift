/// SettingsView — Configuration window for the DGInf provider.
///
/// Provides three tabs:
///   - **General**: Coordinator URL, API key, auto-start on login
///   - **Availability**: Idle timeout slider, availability schedule
///   - **Model**: Select which model to serve, download new models
///
/// All settings are persisted via UserDefaults through the StatusViewModel's
/// published properties (which write to UserDefaults in their didSet).

import SwiftUI

/// The settings window with tabbed sections.
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

            ModelTab(viewModel: viewModel)
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - General Tab

/// Coordinator connection and startup settings.
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
            } header: {
                Text("Startup")
                    .font(.headline)
            }

            Section {
                HStack {
                    Text("Provider Binary:")
                        .foregroundColor(.secondary)
                    if let path = ProviderManager.resolveBinaryPath() {
                        Text(path)
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Not found")
                            .font(.caption)
                            .foregroundColor(.red)
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

/// Idle timeout and availability schedule settings.
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

            Section {
                Text("Schedule support coming soon. Currently the provider runs whenever started and pauses only based on idle detection.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Schedule")
                    .font(.headline)
            }
        }
        .padding()
        .onAppear {
            selectedTimeout = viewModel.idleTimeoutSeconds
        }
    }
}

// MARK: - Model Tab

/// Model selection and download interface.
private struct ModelTab: View {
    @ObservedObject var viewModel: StatusViewModel
    @State private var newModelId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model")
                .font(.headline)

            // Currently selected model
            HStack {
                Text("Active:")
                    .foregroundColor(.secondary)
                Text(viewModel.currentModel)
                    .fontWeight(.medium)
            }

            Divider()

            // Available models list
            Text("Available Models")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if viewModel.modelManager.availableModels.isEmpty {
                Text("No models found in ~/.cache/huggingface/hub/")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                List(viewModel.modelManager.availableModels) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name)
                                .fontWeight(.medium)
                            Text(model.id)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(ModelManager.formatSize(model.sizeBytes))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if model.isMLX {
                            Text("MLX")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .cornerRadius(4)
                        }

                        if viewModel.currentModel == model.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Select") {
                                viewModel.currentModel = model.id
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(height: 120)
            }

            Divider()

            // Download new model
            HStack {
                TextField("Model ID (e.g., mlx-community/Qwen3.5-4B-4bit)", text: $newModelId)
                    .textFieldStyle(.roundedBorder)

                Button("Download") {
                    guard !newModelId.isEmpty else { return }
                    viewModel.modelManager.downloadModel(newModelId)
                    newModelId = ""
                }
                .disabled(viewModel.modelManager.isDownloading || newModelId.isEmpty)
            }

            if viewModel.modelManager.isDownloading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.modelManager.downloadStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button("Refresh Model List") {
                viewModel.modelManager.scanModels()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .onAppear {
            viewModel.modelManager.scanModels()
        }
    }
}
