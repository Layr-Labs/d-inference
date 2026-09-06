import SwiftUI

/// A model list and provider snapshot are supplied by the product shell. This
/// surface does not construct a library or infer enrollment/account readiness.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProductSectionHeader(
                "Local-only AI",
                detail: store.isLive && modelsAreLive ? "Runs on this Mac" : "Sample / unconnected data"
            )
            Text("Try an installed model without network enrollment. Local requests use this Mac’s loopback endpoint and API key.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.localStart.hasActiveSession {
                sessionControls
            } else if let conflict {
                Text(conflict.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Provider Controls", action: onOpenProviderControls)
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                }
                failureMessage
            } else {
                modelControls
                failureMessage
            }
        }
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var modelControls: some View {
        if installed.isEmpty {
            Text(emptyModelMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Open Models", action: onOpenModels)
                .buttonStyle(.bordered)
        } else {
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
            .frame(maxWidth: 480, alignment: .leading)

            if let selected, let issue = modelIssue(selected) {
                Text(issue).font(.system(size: 11)).foregroundStyle(ProductPalette.warning)
            }
            HStack(spacing: 12) {
                Button("Start Local AI") {
                    guard let selected else { return }
                    store.startLocalOnly(
                        modelID: selected.id, models: models, modelsAreLive: modelsAreLive,
                        providerSnapshot: providerSnapshot, onProcessChange: onProcessChange
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.isLive || !modelsAreLive || !store.localStart.isLaunchSupported || selected == nil || selected.map { modelIssue($0) != nil } == true)
                Button("Manage Models", action: onOpenModels)
            }
            Text("Keep Darkbloom open while using this local session. Models load when first requested, so the first response may take longer.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        if store.isLive && modelsAreLive && !store.localStart.isLaunchSupported {
            Text(LocalAPIStartError.nonReplacingLaunchUnavailable.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open Diagnostics", action: onOpenDiagnostics)
        }
        if !store.isLive || !modelsAreLive {
            Text("Sample models cannot launch a real provider. Open the live app to start local AI.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if store.localStart.state.isWaiting || store.localStart.state == .cancelling {
                    ProgressView().controlSize(.small)
                }
                Text(sessionMessage)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if case .ready = store.localStart.state {
                    Button("Try in Chat", action: onOpenChat)
                        .buttonStyle(.borderedProminent)
                }
                if case .failed = store.localStart.state {
                    Button("Check Again") { store.localStart.checkAgain() }
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                }
                Button(store.localStart.state.isWaiting ? "Cancel Start" : "End Local Session") {
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
                .textSelection(.enabled)
            Button("Open Diagnostics", action: onOpenDiagnostics)
        } else if case .cancelled = store.localStart.state {
            Text("The start request was cancelled. Endpoint status below reflects the latest observation.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var sessionMessage: String {
        switch store.localStart.state {
        case .starting(let id): "Starting local AI for \(modelName(id))…"
        case .waitingForEndpoint(let id): "Waiting for a verified endpoint advertising \(modelName(id))…"
        case .ready(let id): "The endpoint is responding and advertises \(modelName(id)). Ready for a first request."
        case .cancelling: "Ending this app’s local session…"
        case .failed(let error): error.localizedDescription
        case .cancelled: "Local start cancelled."
        case .idle: "Local session idle."
        }
    }

    private func modelName(_ id: String) -> String {
        models.first(where: { $0.id == id })?.displayName ?? id
    }

    private var emptyModelMessage: String {
        switch catalogState {
        case .loading: "Checking this Mac’s installed models…"
        case .offline: "The model library is unavailable. Open Models to refresh the installed list."
        case .available: "Install a model in Models, then return here to start local AI."
        }
    }

    private func modelIssue(_ model: ModelSummary) -> String? {
        do {
            try LocalAPIStartPreflight.validateModel(modelID: model.id, models: [model], modelsAreLive: true)
            return nil
        } catch { return error.localizedDescription }
    }
}
