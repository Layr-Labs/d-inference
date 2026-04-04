/// SetupWizardView — Warm, vibrant onboarding wizard for first-time users.
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

    private let stepColors: [Color] = [.coral, .blueAccent, .purpleAccent, .gold, .tealAccent, .coral]
    private let stepIcons: [String] = ["hand.wave.fill", "shield.checkered", "lock.fill", "square.and.arrow.down", "stethoscope", "bolt.fill"]
    private let stepTitles: [String] = ["Welcome", "Security", "MDM", "Model", "Verify", "Launch"]

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 8)

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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)

            // Error message
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.warmError)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Navigation bar
            navBar
        }
        .frame(width: 620, height: 460)
        .background(Color.warmBg)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<totalSteps, id: \.self) { i in
                let isActive = i == currentStep
                let isDone = i < currentStep
                let color = stepColors[i]

                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(isDone ? color : (isActive ? color : Color.warmBgElevated))
                            .frame(width: 36, height: 36)
                            .shadow(color: isActive ? color.opacity(0.4) : .clear, radius: 8)

                        if isDone {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: stepIcons[i])
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isActive ? .white : Color.warmInkFaint)
                        }
                    }

                    Text(stepTitles[i])
                        .font(.system(size: 10, weight: isActive ? .bold : .medium, design: .rounded))
                        .foregroundStyle(isActive ? color : (isDone ? Color.warmInk : Color.warmInkFaint))
                }
                .frame(maxWidth: .infinity)

                if i < totalSteps - 1 {
                    Rectangle()
                        .fill(i < currentStep ? stepColors[i] : Color.warmBgElevated)
                        .frame(height: 2)
                        .frame(maxWidth: 30)
                        .offset(y: -10)
                }
            }
        }
    }

    // MARK: - Navigation Bar

    private var navBar: some View {
        HStack {
            if currentStep > 0 {
                Button {
                    currentStep -= 1
                    errorMessage = ""
                } label: {
                    Label("Back", systemImage: "arrow.left")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .buttonStyle(WarmButtonStyle(.warmInkFaint, filled: false))
                .disabled(isProcessing)
                .pointerOnHover()
            }

            Spacer()

            if currentStep < totalSteps - 1 {
                Button {
                    Task { await advanceStep() }
                } label: {
                    HStack(spacing: 6) {
                        if isProcessing || isDownloadingModel || isInstallingCLI {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text("Continue")
                        Image(systemName: "arrow.right")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .buttonStyle(WarmButtonStyle(stepColors[currentStep]))
                .disabled(isProcessing || isDownloadingModel || isInstallingCLI)
                .pointerOnHover()
            } else {
                Button {
                    viewModel.hasCompletedSetup = true
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                        Text("Start Earning")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .buttonStyle(WarmButtonStyle(.tealAccent))
                .pointerOnHover()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.warmBgSecondary.opacity(0.5))
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        let guide = GuideMessages.welcome(chipName: viewModel.chipName, memoryGB: viewModel.memoryGB)
        return VStack(alignment: .leading, spacing: 20) {
            GuideAvatarView(
                mood: .greeting,
                message: guide.message,
                detail: guide.detail
            )

            // Hardware cards
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                hwChip(icon: "cpu", color: .blueAccent, label: "Chip", value: viewModel.chipName)
                hwChip(icon: "gpu", color: .gold, label: "GPU", value: "\(viewModel.gpuCores) Cores")
                hwChip(icon: "memorychip", color: .purpleAccent, label: "Memory", value: "\(viewModel.memoryGB) GB Unified")
                hwChip(icon: "bolt", color: .tealAccent, label: "Bandwidth", value: "\(viewModel.memoryBandwidthGBs) GB/s")
            }

            if !viewModel.securityManager.binaryFound {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.gold)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Provider binary not found")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        if isInstallingCLI {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Installing...")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(.warmInkLight)
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
                            .buttonStyle(WarmButtonStyle(.gold))
                            .controlSize(.small)
                            .pointerOnHover()
                        }
                    }
                }
                .padding(14)
                .background(Color.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gold.opacity(0.2), lineWidth: 1.5))
            }

        }
    }

    // MARK: - Step 2: Security

    private var securityStep: some View {
        let allPassed = viewModel.securityManager.sipEnabled && viewModel.securityManager.secureEnclaveAvailable
        let guide = GuideMessages.security(allPassed: allPassed)
        return VStack(alignment: .leading, spacing: 16) {
            GuideAvatarView(
                mood: allPassed ? .excited : .explaining,
                message: guide.message,
                detail: guide.detail
            )

            VStack(spacing: 10) {
                checkRow("System Integrity Protection (SIP)",
                         subtitle: "Prevents memory inspection by other processes",
                         passed: viewModel.securityManager.sipEnabled, color: .blueAccent)
                checkRow("Secure Enclave",
                         subtitle: "Hardware-bound identity key for attestation",
                         passed: viewModel.securityManager.secureEnclaveAvailable, color: .purpleAccent)
                checkRow("Secure Boot",
                         subtitle: "Ensures only trusted software runs at boot",
                         passed: viewModel.securityManager.secureBootEnabled, color: .tealAccent)
            }

            if viewModel.securityManager.isChecking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking security posture...")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.warmInkLight)
                }
            }

        }
        .task {
            await viewModel.securityManager.refresh()
        }
    }

    // MARK: - Step 3: MDM

    private var mdmStep: some View {
        let guide = GuideMessages.mdm(enrolled: viewModel.securityManager.mdmEnrolled)
        return VStack(alignment: .leading, spacing: 16) {
            GuideAvatarView(
                mood: viewModel.securityManager.mdmEnrolled ? .excited : .explaining,
                message: guide.message,
                detail: guide.detail
            )

            HStack(spacing: 12) {
                Image(systemName: viewModel.securityManager.mdmEnrolled ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 28))
                    .foregroundColor(viewModel.securityManager.mdmEnrolled ? .tealAccent : .warmInkFaint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.securityManager.mdmEnrolled ? "Enrolled in DGInf MDM" : "Not enrolled")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(viewModel.securityManager.mdmEnrolled ? Color.tealAccent : Color.warmInk)
                    Text(viewModel.securityManager.mdmEnrolled
                         ? "Your Mac is verified for hardware trust."
                         : "MDM enrollment enables full hardware attestation.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.warmInkLight)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill((viewModel.securityManager.mdmEnrolled ? Color.tealAccent : Color.warmInkFaint).opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder((viewModel.securityManager.mdmEnrolled ? Color.tealAccent : Color.warmInkFaint).opacity(0.15), lineWidth: 1.5))
            )

            if !viewModel.securityManager.mdmEnrolled {
                Button("Enroll Now") {
                    Task { await enrollMDM() }
                }
                .buttonStyle(WarmButtonStyle(.purpleAccent))
                .disabled(isProcessing)
                .pointerOnHover()

                Text("Downloads an enrollment profile and opens System Settings.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.warmInkFaint)
            }

            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(statusMessage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.warmInkLight)
                }
            }

        }
    }

    // MARK: - Step 4: Model

    private var modelStep: some View {
        let guide = isDownloadingModel
            ? GuideMessages.downloading(modelName: selectedModelId.components(separatedBy: "/").last ?? "model")
            : GuideMessages.model(memoryGB: viewModel.memoryGB)
        return VStack(alignment: .leading, spacing: 16) {
            GuideAvatarView(
                mood: isDownloadingModel ? .thinking : .explaining,
                message: guide.message,
                detail: guide.detail
            )

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
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.warmInkLight)
                }
            }

            if !downloadStatus.isEmpty && !isDownloadingModel {
                Text(downloadStatus)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(downloadStatus.contains("\u{2713}") ? .tealAccent : .warmError)
            }

        }
    }

    // MARK: - Step 5: Verify

    private var verifyStep: some View {
        let passed = doctorOutput.contains("8/8") || doctorOutput.contains("7/8")
        let guide = GuideMessages.verify(passed: !doctorOutput.isEmpty && passed)
        return VStack(alignment: .leading, spacing: 16) {
            GuideAvatarView(
                mood: doctorOutput.isEmpty ? .thinking : (passed ? .excited : .concerned),
                message: doctorOutput.isEmpty ? "Let me check everything..." : guide.message,
                detail: doctorOutput.isEmpty ? "Running diagnostics now." : guide.detail
            )

            if doctorOutput.isEmpty && !isProcessing {
                Button("Run Diagnostics") {
                    Task { await runDoctor() }
                }
                .buttonStyle(WarmButtonStyle(.tealAccent))
                .pointerOnHover()
            }

            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Running doctor checks...")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(.warmInkLight)
                }
            }

            if !doctorOutput.isEmpty {
                ScrollView {
                    Text(doctorOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.warmBgSecondary, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.warmInk.opacity(0.08), lineWidth: 1))
                }
            }

        }
        .task {
            if doctorOutput.isEmpty {
                await runDoctor()
            }
        }
    }

    // MARK: - Step 6: Start

    private var startStep: some View {
        VStack(spacing: 24) {
            GuideAvatarView(
                mood: .celebrating,
                message: GuideMessages.ready.message,
                detail: GuideMessages.ready.detail
            )

            // Summary cards
            VStack(spacing: 10) {
                if !selectedModelId.isEmpty {
                    summaryRow(icon: "cpu", color: .gold, label: "Model", value: selectedModelId.components(separatedBy: "/").last ?? selectedModelId)
                }
                summaryRow(icon: viewModel.securityManager.trustLevel.iconName, color: .tealAccent,
                           label: "Trust", value: viewModel.securityManager.trustLevel.displayName)
                summaryRow(icon: viewModel.securityManager.sipEnabled ? "lock.fill" : "lock.open",
                           color: viewModel.securityManager.sipEnabled ? .blueAccent : .warmError,
                           label: "SIP", value: viewModel.securityManager.sipEnabled ? "Enabled" : "Disabled")
                summaryRow(icon: viewModel.securityManager.mdmEnrolled ? "checkmark.shield.fill" : "shield",
                           color: viewModel.securityManager.mdmEnrolled ? .purpleAccent : .warmInkFaint,
                           label: "MDM", value: viewModel.securityManager.mdmEnrolled ? "Enrolled" : "Not enrolled")
            }

            Toggle(isOn: $viewModel.autoStart) {
                Text("Start provider automatically on login")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .tint(.tealAccent)

        }
    }

    // MARK: - Reusable Components

    private func hwChip(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: color.opacity(0.3), radius: 3, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.warmInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.15), lineWidth: 1.5))
    }

    private func checkRow(_ title: String, subtitle: String, passed: Bool, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(passed ? color : .warmError)
                .shadow(color: (passed ? color : .warmError).opacity(0.3), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.warmInk)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.warmInkFaint)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill((passed ? color : .warmError).opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder((passed ? color : .warmError).opacity(0.12), lineWidth: 1.5))
        )
    }

    private func summaryRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 8))
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.warmInkLight)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.warmInk)
        }
        .padding(10)
        .background(color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func modelRow(_ model: ModelCatalog.Entry) -> some View {
        let fits = model.sizeGB <= Double(viewModel.memoryGB - 4)
        let isSelected = selectedModelId == model.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(fits ? Color.warmInk : Color.warmInkFaint)
                Text("\(String(format: "%.1f", model.sizeGB)) GB")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.warmInkFaint)
            }

            Spacer()

            if !fits {
                Text("Too large")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.warmError)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.tealAccent)
                    .shadow(color: .tealAccent.opacity(0.3), radius: 4)
            } else {
                Button("Select") {
                    selectedModelId = model.id
                    viewModel.currentModel = model.id
                    Task { await downloadModelIfNeeded(model) }
                }
                .buttonStyle(WarmButtonStyle(.gold, filled: false))
                .controlSize(.small)
                .disabled(isDownloadingModel)
                .pointerOnHover()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.tealAccent.opacity(0.08) : Color.white.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(isSelected ? Color.tealAccent.opacity(0.25) : Color.warmInk.opacity(0.06), lineWidth: isSelected ? 2 : 1)
                )
        )
    }

    // MARK: - Actions

    private func advanceStep() async {
        errorMessage = ""

        switch currentStep {
        case 0:
            currentStep += 1
        case 1:
            await viewModel.securityManager.refresh()
            if !viewModel.securityManager.sipEnabled {
                errorMessage = "SIP must be enabled to serve inference safely.\nTo enable SIP:\n1. Shut down your Mac completely\n2. Press and hold the power button until \"Loading startup options\" appears\n3. Select Options \u{2192} Continue\n4. From the menu bar: Utilities \u{2192} Terminal\n5. Type: csrutil enable\n6. Restart your Mac"
                return
            }
            currentStep += 1
        case 2:
            await viewModel.securityManager.refresh()
            currentStep += 1
        case 3:
            if selectedModelId.isEmpty {
                errorMessage = "Please select a model to continue."
                return
            }
            currentStep += 1
        case 4:
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
