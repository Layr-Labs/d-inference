/// SetupWizardView — Multi-step onboarding for first-time users.
///
/// Mirrors the CLI `dginf-provider install` flow with a graphical UI:
///   1. Welcome & hardware detection
///   2. Security verification
///   3. MDM enrollment
///   4. Model selection & download
///   5. Verification (doctor)
///   6. Start provider

import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var viewModel: StatusViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0
    @State private var isProcessing = false
    @State private var statusMessage = ""
    @State private var errorMessage = ""
    @State private var selectedModelId = ""
    @State private var doctorOutput = ""
    @State private var isInstallingCLI = false
    @State private var isDownloadingModel = false
    @State private var downloadStatus = ""

    private let totalSteps = 6

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar + step indicator
            if #available(macOS 26.0, *) {
                HStack {
                    Text("Step \(currentStep + 1) of \(totalSteps)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ProgressView(value: Double(currentStep), total: Double(totalSteps - 1))
                }
                .padding(8)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .glassEffect(in: .rect(cornerRadius: 8))
            } else {
                ProgressView(value: Double(currentStep), total: Double(totalSteps - 1))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                HStack {
                    Text("Step \(currentStep + 1) of \(totalSteps)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
            }

            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: securityStep
                case 2: mdmStep
                case 3: modelStep
                case 4: verifyStep
                case 5: startStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                        errorMessage = ""
                    }
                    .disabled(isProcessing)
                }

                Spacer()

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(10)
                        .frame(maxWidth: 400)
                }

                Spacer()

                if currentStep < totalSteps - 1 {
                    if #available(macOS 26.0, *) {
                        Button("Continue") {
                            Task { await advanceStep() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isProcessing || isDownloadingModel || isInstallingCLI)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    } else {
                        Button("Continue") {
                            Task { await advanceStep() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isProcessing || isDownloadingModel || isInstallingCLI)
                    }
                } else {
                    if #available(macOS 26.0, *) {
                        Button("Done") {
                            viewModel.hasCompletedSetup = true
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    } else {
                        Button("Done") {
                            viewModel.hasCompletedSetup = true
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 600, height: 500)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to DGInf")
                .font(.title)
                .fontWeight(.bold)

            Text("Decentralized Private Inference")
                .font(.title3)
                .foregroundColor(.secondary)

            Text("DGInf turns your Mac into a private inference provider. Your GPU serves AI models while cryptographic protections ensure nobody — not even you — can read the prompts being processed.")
                .font(.body)

            Divider()

            Text("Your Hardware")
                .font(.headline)

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(viewModel.chipName, systemImage: "cpu")
                    Label("\(viewModel.memoryGB) GB Unified Memory", systemImage: "memorychip")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(viewModel.gpuCores) GPU Cores", systemImage: "gpu")
                    Label("\(viewModel.memoryBandwidthGBs) GB/s Bandwidth", systemImage: "bolt")
                }
            }
            .font(.subheadline)

            if !viewModel.securityManager.binaryFound {
                VStack(alignment: .leading, spacing: 8) {
                    Label("dginf-provider binary not found.", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.subheadline)

                    if isInstallingCLI {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Installing...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Install Now") {
                            Task {
                                isInstallingCLI = true
                                let result = await CLIRunner.shell("curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash")
                                if result.success {
                                    viewModel.securityManager.binaryFound = CLIRunner.resolveBinaryPath() != nil
                                } else {
                                    errorMessage = result.stderr.isEmpty ? "Installation failed" : result.stderr
                                }
                                isInstallingCLI = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 2: Security

    private var securityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Security Check")
                .font(.title2)
                .fontWeight(.bold)

            Text("DGInf requires several macOS security features to ensure prompts are protected during inference.")
                .font(.body)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                securityRow(
                    "System Integrity Protection (SIP)",
                    enabled: viewModel.securityManager.sipEnabled,
                    detail: "Prevents memory inspection by other processes"
                )
                securityRow(
                    "Secure Enclave",
                    enabled: viewModel.securityManager.secureEnclaveAvailable,
                    detail: "Hardware-bound identity key for attestation"
                )
                securityRow(
                    "Secure Boot",
                    enabled: viewModel.securityManager.secureBootEnabled,
                    detail: "Ensures only trusted software runs at boot"
                )
            }

            if viewModel.securityManager.isChecking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking security posture...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    // MARK: - Step 3: MDM Enrollment

    private var mdmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MDM Enrollment")
                .font(.title2)
                .fontWeight(.bold)

            Text("Device enrollment lets the coordinator independently verify your Mac's security posture. This is required for hardware trust — without it, your provider won't receive inference requests.")
                .font(.body)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Image(systemName: viewModel.securityManager.mdmEnrolled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(viewModel.securityManager.mdmEnrolled ? .green : .secondary)
                Text(viewModel.securityManager.mdmEnrolled ? "Enrolled in DGInf MDM" : "Not enrolled")
                    .fontWeight(.medium)
            }

            if !viewModel.securityManager.mdmEnrolled {
                Button("Enroll Now") {
                    Task { await enrollMDM() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing)

                Text("This will download an enrollment profile and open System Settings. Follow the prompts to install it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if isProcessing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 4: Model Selection

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select a Model")
                .font(.title2)
                .fontWeight(.bold)

            Text("Choose a model to serve. Smaller models are faster to download and use less memory.")
                .font(.body)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(ModelCatalog.models, id: \.id) { model in
                        modelRow(model)
                    }
                }
            }

            if isDownloadingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(downloadStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !downloadStatus.isEmpty && !isDownloadingModel {
                Text(downloadStatus)
                    .font(.caption)
                    .foregroundColor(downloadStatus.contains("\u{2713}") ? .green : .red)
            }

            if isProcessing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Step 5: Verify

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verification")
                .font(.title2)
                .fontWeight(.bold)

            Text("Running diagnostics to make sure everything is configured correctly.")
                .font(.body)
                .foregroundColor(.secondary)

            if doctorOutput.isEmpty && !isProcessing {
                Button("Run Diagnostics") {
                    Task { await runDoctor() }
                }
                .buttonStyle(.borderedProminent)
            }

            if isProcessing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Running doctor checks...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if !doctorOutput.isEmpty {
                ScrollView {
                    Text(doctorOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.textBackgroundColor))
                        .cornerRadius(6)
                }
            }

            Spacer()
        }
        .task {
            if doctorOutput.isEmpty {
                await runDoctor()
            }
        }
    }

    // MARK: - Step 6: Start

    private var startStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to Go!")
                .font(.title2)
                .fontWeight(.bold)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Your Mac is configured as a DGInf inference provider. Click Done to start serving.")
                .font(.body)

            VStack(alignment: .leading, spacing: 8) {
                if !selectedModelId.isEmpty {
                    Label("Model: \(selectedModelId)", systemImage: "cpu")
                }
                Label("Trust: \(viewModel.securityManager.trustLevel.displayName)", systemImage: viewModel.securityManager.trustLevel.iconName)
                Label("SIP: \(viewModel.securityManager.sipEnabled ? "Enabled" : "Disabled")", systemImage: viewModel.securityManager.sipEnabled ? "lock.fill" : "lock.open")
                Label("MDM: \(viewModel.securityManager.mdmEnrolled ? "Enrolled" : "Not enrolled")", systemImage: viewModel.securityManager.mdmEnrolled ? "checkmark.shield.fill" : "shield")
            }
            .font(.subheadline)

            Toggle("Start provider automatically on login", isOn: $viewModel.autoStart)

            Spacer()
        }
    }

    // MARK: - Helpers

    private func securityRow(_ title: String, enabled: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(enabled ? .green : .red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func modelRow(_ model: ModelCatalog.Entry) -> some View {
        let fits = model.sizeGB <= Double(viewModel.memoryGB - 4)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).fontWeight(.medium)
                Text("\(String(format: "%.1f", model.sizeGB)) GB")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !fits {
                Text("Too large")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if selectedModelId == model.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Select") {
                    selectedModelId = model.id
                    viewModel.currentModel = model.id
                    Task { await downloadModelIfNeeded(model) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!fits || isDownloadingModel)
            }
        }
        .padding(8)
        .background(selectedModelId == model.id ? Color.accentColor.opacity(0.1) : Color.clear)
        .cornerRadius(6)
    }

    private func advanceStep() async {
        errorMessage = ""

        switch currentStep {
        case 0:
            // Welcome — just advance
            currentStep += 1
        case 1:
            // Security — refresh and advance
            await viewModel.securityManager.refresh()
            if !viewModel.securityManager.sipEnabled {
                errorMessage = "SIP must be enabled to serve inference safely.\nTo enable SIP:\n1. Shut down your Mac completely\n2. Press and hold the power button until \"Loading startup options\" appears\n3. Select Options \u{2192} Continue\n4. From the menu bar: Utilities \u{2192} Terminal\n5. Type: csrutil enable\n6. Restart your Mac"
                return
            }
            currentStep += 1
        case 2:
            // MDM — can skip if already enrolled
            await viewModel.securityManager.refresh()
            currentStep += 1
        case 3:
            // Model — ensure one is selected
            if selectedModelId.isEmpty {
                errorMessage = "Please select a model."
                return
            }
            currentStep += 1
        case 4:
            // Verify — just advance
            currentStep += 1
        default:
            break
        }
    }

    private func enrollMDM() async {
        isProcessing = true
        statusMessage = "Downloading enrollment profile..."

        do {
            let result = try await CLIRunner.run(["enroll"])
            if result.success {
                statusMessage = "Profile downloaded. Follow the System Settings prompt to install."
                // Wait a moment, then re-check
                try? await Task.sleep(for: .seconds(3))
                await viewModel.securityManager.refresh()
            } else {
                errorMessage = result.stderr.isEmpty ? "Enrollment failed" : result.stderr
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessing = false
    }

    private func runDoctor() async {
        isProcessing = true
        do {
            let result = try await CLIRunner.run([
                "doctor", "--coordinator", viewModel.coordinatorURL
            ])
            doctorOutput = result.output
        } catch {
            doctorOutput = "Failed to run doctor: \(error.localizedDescription)"
        }
        isProcessing = false
    }

    private func downloadModelIfNeeded(_ model: ModelCatalog.Entry) async {
        // Check if model is already downloaded
        let alreadyDownloaded = viewModel.modelManager.availableModels.contains { $0.id == model.id }
        if alreadyDownloaded {
            downloadStatus = ""
            return
        }

        isDownloadingModel = true
        downloadStatus = "Downloading \(model.name) (\(String(format: "%.1f", model.sizeGB)) GB)... This may take several minutes."

        do {
            let result = try await CLIRunner.run(["models", "download", "--model", model.id])
            if result.success {
                downloadStatus = "Download complete \u{2713}"
                viewModel.modelManager.scanModels()
            } else {
                // Fallback: download from S3
                let s3Result = try await CLIRunner.run(["models", "download-s3", "--model", model.id])
                if s3Result.success {
                    downloadStatus = "Download complete \u{2713}"
                    viewModel.modelManager.scanModels()
                } else {
                    downloadStatus = "Download failed: \(result.stderr)"
                }
            }
        } catch {
            downloadStatus = "Download failed: \(error.localizedDescription)"
        }

        isDownloadingModel = false
    }
}
