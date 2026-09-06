import SwiftUI

/// Selection and lifecycle policy remain owned by the supplied stores.
struct LocalAPIStartControls: View {
    let store: LocalAPIStore
    let models: [ModelSummary]
    let modelsAreLive: Bool
    let catalogState: ModelCatalogState
    let providerSnapshot: ProviderSnapshot?
    let onOpenModels: () -> Void
    let onOpenChat: () -> Void
    let onOpenProviderControls: () -> Void
    let onOpenDiagnostics: () -> Void
    let onSelectModel: (String) -> Void
    let onProcessChange: @MainActor () -> Void

    private var installed: [ModelSummary] { models.filter(\.isInstalled) }
    private var selected: ModelSummary? { installed.first { $0.id == store.selectedLocalModelID } }
    private var conflict: LocalAPIStartConflict? { store.startConflict(providerSnapshot: providerSnapshot) }
    private var canStart: Bool {
        store.isLive && modelsAreLive && store.localStart.isLaunchSupported
            && selected != nil && selected.map { modelIssue($0) == nil } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Model")
                    .font(DarkbloomTheme.chivo(19, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                if !store.isLive || !modelsAreLive {
                    Text("Sample / unconnected data")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioPalette.secondaryInk)
                }
                Spacer(minLength: 0)
                Button("Open Library", action: onOpenModels)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.accent)
            }

            if store.localStart.hasActiveSession {
                sessionControls
            } else if let conflict {
                Text(conflict.message)
                    .font(.system(size: 13))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Provider controls", action: onOpenProviderControls)
                    Button("Diagnostics", action: onOpenDiagnostics)
                }
                failureMessage
            } else {
                modelControls
                failureMessage
            }
        }
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
    }

    @ViewBuilder
    private var modelControls: some View {
        if installed.isEmpty {
            Text(emptyModelMessage)
                .font(.system(size: 13))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    modelPicker
                    startButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    modelPicker
                    startButton
                }
            }

            if let selected, let issue = modelIssue(selected) {
                Text(issue)
                    .font(.system(size: 12))
                    .foregroundStyle(ProductPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Keep Darkbloom open. The first request loads the model.")
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
        }
        if store.isLive && modelsAreLive && !store.localStart.isLaunchSupported {
            Text(LocalAPIStartError.nonReplacingLaunchUnavailable.localizedDescription)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Button("Diagnostics", action: onOpenDiagnostics)
        }
        if !store.isLive || !modelsAreLive {
            Text("Sample data cannot start a model.")
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
        }
    }

    private var modelPicker: some View {
        Picker("Installed model", selection: Binding(
            get: { store.selectedLocalModelID },
            set: { selection in
                store.selectedLocalModelID = selection
                if let selection { onSelectModel(selection) }
            }
        )) {
            Text("Choose a model").tag(String?.none)
            ForEach(installed) { model in
                Text(installed.filter { $0.displayName == model.displayName }.count > 1 ? model.id : model.displayName)
                    .tag(Optional(model.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.large)
        .font(.system(size: 14, weight: .medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(selected?.id ?? "Choose an installed model")
        .accessibilityLabel("Installed model")
    }

    private var startButton: some View {
        Button("Start model") {
            guard let selected else { return }
            store.startLocalOnly(
                modelID: selected.id, models: models, modelsAreLive: modelsAreLive,
                providerSnapshot: providerSnapshot, onProcessChange: onProcessChange
            )
        }
        .buttonStyle(StudioPrimaryButtonStyle())
        .disabled(!canStart)
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if store.localStart.state.isWaiting || store.localStart.state == .cancelling {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Updating local session")
                }
                Text(sessionMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(sessionHasFailed ? ProductPalette.warning : StudioPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 14) {
                if case .ready = store.localStart.state {
                    Button("Open chat", action: onOpenChat)
                }
                if case .failed = store.localStart.state {
                    Button("Check again") { store.localStart.checkAgain() }
                    Button("Diagnostics", action: onOpenDiagnostics)
                }
                Button(store.localStart.state.isWaiting ? "Cancel start" : "End local session") {
                    store.localStart.cancel()
                }
                .disabled(store.localStart.state == .cancelling)
            }
        }
    }

    @ViewBuilder
    private var failureMessage: some View {
        if case .failed(let error) = store.localStart.state {
            Text(error.localizedDescription)
                .font(.system(size: 12))
                .foregroundStyle(ProductPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Diagnostics", action: onOpenDiagnostics)
        } else if case .cancelled = store.localStart.state {
            Text("Start cancelled. Connection status is shown below.")
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
        }
    }

    private var sessionHasFailed: Bool {
        if case .failed = store.localStart.state { return true }
        return false
    }

    private var sessionMessage: String {
        switch store.localStart.state {
        case .starting(let id): "Starting \(modelName(id))…"
        case .waitingForEndpoint(let id): "Waiting for the endpoint to respond and list \(modelName(id))…"
        case .ready(let id): "Selected model: \(modelName(id)). Models load when needed."
        case .cancelling: "Ending this app’s local session…"
        case .failed(let error): error.localizedDescription
        case .cancelled: "Local start cancelled."
        case .idle: "No local session."
        }
    }

    private func modelName(_ id: String) -> String {
        models.first(where: { $0.id == id })?.displayName ?? id
    }

    private var emptyModelMessage: String {
        switch catalogState {
        case .loading: "Checking installed models…"
        case .offline: "The model library is unavailable. Open Library to refresh it."
        case .available: "Install a model from Library to get started."
        }
    }

    private func modelIssue(_ model: ModelSummary) -> String? {
        do {
            try LocalAPIStartPreflight.validateModel(modelID: model.id, models: [model], modelsAreLive: true)
            return nil
        } catch { return error.localizedDescription }
    }
}
