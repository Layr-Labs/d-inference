import SwiftUI

struct PreparationStepView: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    let isCompact: Bool

    var body: some View {
        OnboardingStageScaffold(step: .preparation, isCompact: isCompact) {
            VStack(alignment: .leading, spacing: 13) {
                actions
                Text(detail)
                    .font(DarkbloomTheme.chivo(10))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } visual: {
            PreparationSurface(flow: flow, identity: identity)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.preparationPhase {
        case .reservingSpace, .loadingCatalog:
            workingButton("Loading compatible models…")
        case .choosingModel:
            OnboardingPrimaryButton(
                title: flow.selectedPreparationChoice?.isInstalled == true
                    ? "Start provider and local API"
                    : "Download and start",
                systemImage: "arrow.down.circle",
                isDisabled: flow.selectedPreparationChoice == nil
            ) {
                flow.startPreparation()
            }
            .keyboardShortcut(.defaultAction)
        case .downloading:
            workingButton("Downloading verified model…")
        case .verifying:
            workingButton("Verifying model files…")
        case .startingProvider:
            workingButton("Starting provider and local API…")
        case .ready:
            OnboardingPrimaryButton(title: "Continue", systemImage: "arrow.right") {
                flow.continueToNextStep()
            }
            .keyboardShortcut(.defaultAction)
        case .downloadFailed:
            retryActions(title: "Resume download")
        case .startFailed:
            retryActions(title: "Start provider again")
        case .catalogFailed:
            retryActions(title: "Reload model catalog")
        case .noCompatibleModel:
            retryActions(title: "Check catalog again")
        }
    }

    private func workingButton(_ title: String) -> some View {
        OnboardingPrimaryButton(
            title: title,
            isWorking: true,
            isDisabled: true,
            action: {}
        )
    }

    private func retryActions(title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            OnboardingPrimaryButton(title: title, systemImage: "arrow.clockwise") {
                flow.retryPreparation()
            }
            .keyboardShortcut(.defaultAction)
            OnboardingQuietButton(title: "Run system check", systemImage: "stethoscope") {
                flow.returnToReadinessForSystemCheck()
            }
        }
    }

    private var detail: String {
        if let failure = flow.preparationFailureDetail { return failure }
        if !flow.usesLivePreparation {
            return "Fixture preview · live setup uses the CLI catalog, verified download stream, and noninteractive provider start."
        }
        return switch flow.preparationPhase {
        case .choosingModel:
            "The recommendation comes from the live catalog's minimum-RAM and size data for \(identity.chipName). Choose any compatible model before continuing."
        case .ready:
            "The provider start command completed with the selected model and a local OpenAI-compatible endpoint."
        default:
            "Downloads resume from verified partial files after an interruption. Darkbloom starts only after the CLI confirms completion."
        }
    }
}

private struct PreparationSurface: View {
    let flow: OnboardingFlowModel
    let identity: MachineIdentity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Int {
        Int((flow.preparationProgress * 100).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(flow.usesLivePreparation ? "PRIVATE MODEL" : "MODEL PREPARATION PREVIEW")
                        .font(DarkbloomTheme.chivo(9, weight: .medium))
                        .tracking(1.05)
                    Text(flow.usesLivePreparation ? phaseSubtitle : "SIMULATED · no model or files changed")
                        .font(DarkbloomTheme.chivo(10))
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.44))
                }
                Spacer()
                Image(systemName: "cube.transparent")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(DarkbloomTheme.accent)
            }

            Rectangle()
                .fill(DarkbloomTheme.ink.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 16)

            if flow.usesLivePreparation {
                liveChoice
            } else {
                previewChoice
            }

            Spacer(minLength: 12)

            HStack(alignment: .firstTextBaseline) {
                Text(phaseTitle)
                    .font(DarkbloomTheme.chivo(13, weight: .medium))
                Spacer()
                Text("\(percent)%")
                    .font(DarkbloomTheme.chivo(12, weight: .medium))
                    .foregroundStyle(DarkbloomTheme.accent)
                    .monospacedDigit()
            }

            ProgressView(value: flow.preparationProgress)
                .progressViewStyle(.linear)
                .tint(isFailure ? .orange : DarkbloomTheme.accent)
                .padding(.top, 9)

            HStack(spacing: 15) {
                phasePill("CHOOSE", complete: hasChosen)
                phasePill("DOWNLOAD", complete: downloadComplete)
                phasePill("START", complete: flow.preparationPhase == .ready)
            }
            .padding(.top, 17)
        }
        .padding(25)
        .frame(width: 390, height: 420, alignment: .topLeading)
        .onboardingPanel()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: flow.preparationPhase)
    }

    @ViewBuilder
    private var liveChoice: some View {
        if !flow.preparationChoices.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("MODEL FOR THIS MAC")
                    .font(DarkbloomTheme.chivo(8, weight: .medium))
                    .tracking(0.9)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.38))

                Picker("Model", selection: Binding(
                    get: { flow.selectedModelID ?? "" },
                    set: { flow.selectPreparationModel(id: $0) }
                )) {
                    ForEach(flow.preparationChoices) { choice in
                        Text(choice.displayName).tag(choice.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(flow.preparationPhase != .choosingModel)

                if let choice = flow.selectedPreparationChoice {
                    Text(choice.summary)
                        .font(DarkbloomTheme.chivo(11))
                        .foregroundStyle(DarkbloomTheme.ink.opacity(0.62))
                        .lineLimit(3)
                    HStack {
                        fact("DOWNLOAD", choice.isInstalled ? "Already installed" : byteCount(choice.sizeBytes))
                        Spacer()
                        fact("MINIMUM RAM", "\(choice.minimumMemoryGB) GB")
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ProgressView().controlSize(.small)
                Text(flow.preparationFailureDetail ?? "Reading the live catalog and local model cache…")
                    .font(DarkbloomTheme.chivo(11))
                    .lineSpacing(3)
                    .foregroundStyle(DarkbloomTheme.ink.opacity(0.58))
            }
        }
    }

    private var previewChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sample catalog model")
                .font(DarkbloomTheme.chivo(14, weight: .medium))
            Text("Live setup supplies the model id, fit, and exact size from the CLI catalog.")
                .font(DarkbloomTheme.chivo(11))
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.58))
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DarkbloomTheme.chivo(8, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(DarkbloomTheme.ink.opacity(0.36))
            Text(value)
                .font(DarkbloomTheme.chivo(10, weight: .medium))
        }
    }

    private var phaseSubtitle: String {
        switch flow.preparationPhase {
        case .choosingModel: "Compatible catalog models"
        case .ready: "Provider and local endpoint started"
        case .noCompatibleModel: "No confirmed compatible model"
        default: "CLI-managed download and provider start"
        }
    }

    private var phaseTitle: String {
        switch flow.preparationPhase {
        case .reservingSpace, .loadingCatalog: "Checking catalog and local models"
        case .choosingModel: "Choose a compatible model"
        case .downloading: "Downloading model files"
        case .verifying: "Verifying model integrity"
        case .startingProvider: "Starting the provider"
        case .ready: "Provider ready"
        case .downloadFailed: "Download paused"
        case .catalogFailed: "Catalog unavailable"
        case .noCompatibleModel: "No compatible model found"
        case .startFailed: "Provider start needs attention"
        }
    }

    private var isFailure: Bool {
        switch flow.preparationPhase {
        case .downloadFailed, .catalogFailed, .noCompatibleModel, .startFailed: true
        default: false
        }
    }

    private var hasChosen: Bool {
        flow.selectedModelID != nil
    }

    private var downloadComplete: Bool {
        switch flow.preparationPhase {
        case .startingProvider, .ready, .startFailed: true
        default: flow.selectedPreparationChoice?.isInstalled == true
        }
    }

    private func phasePill(_ title: String, complete: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(complete ? DarkbloomTheme.accent : DarkbloomTheme.ink.opacity(0.14))
                .frame(width: 5, height: 5)
            Text(title)
                .font(DarkbloomTheme.chivo(8, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(DarkbloomTheme.ink.opacity(complete ? 0.7 : 0.3))
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }
}
