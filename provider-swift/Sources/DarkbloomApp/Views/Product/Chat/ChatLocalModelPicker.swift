import SwiftUI

/// A selector over the shared library. The existing preflight supplies every
/// eligibility reason; this view contains no model or runtime capability policy.
struct ChatLocalModelPicker: View {
    let store: LocalAPIStore
    let library: ModelLibraryStore
    let onOpenModels: (() -> Void)?
    let onOpenDiagnostics: (() -> Void)?
    let onStart: () -> Void
    let onSelectModel: (String) -> Void

    private var installed: [ModelSummary] { library.installedModels }
    private var selected: ModelSummary? {
        installed.first { $0.id == store.selectedLocalModelID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if installed.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Text(emptyMessage)
                        libraryAction
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(emptyMessage)
                        libraryAction
                    }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        modelPicker
                        Spacer(minLength: 8)
                        startButton
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        modelPicker
                        startButton
                    }
                }
                Text("Start a model on this Mac when you’re ready. Keep Darkbloom open while you work.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.isLive || !library.isLive {
                Text("Sample models can’t start a local session.")
            } else if !store.localStart.isLaunchSupported {
                Text("Local start needs attention before you can use it.")
                if let onOpenDiagnostics {
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                        .buttonStyle(.borderless)
                }
                ChatLocalStartDetails(
                    summary: "Start details",
                    detail: LocalAPIStartError.nonReplacingLaunchUnavailable.localizedDescription
                )
            }

            if let issue = selectionIssue {
                ChatLocalStartDetails(summary: "Choose another model in Library", detail: issue)
                libraryAction
            }
        }
    }

    private var modelPicker: some View {
        Picker("Model to start", selection: Binding(
            get: { store.selectedLocalModelID },
            set: { selection in
                library.selectModel(id: selection)
                store.syncLocalModelSelection(preferredID: selection, models: library.models)
                if let selection { onSelectModel(selection) }
            }
        )) {
            Text("Choose an installed model").tag(String?.none)
            ForEach(installed) { model in
                Text(installed.filter { $0.displayName == model.displayName }.count > 1 ? model.id : model.displayName)
                    .tag(Optional(model.id))
                    .disabled(modelIssue(model) != nil)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityLabel("Model to start on this Mac")
        .accessibilityValue(selected?.displayName ?? "Not selected")
    }

    private var startButton: some View {
        Button("Start model", action: onStart)
            .buttonStyle(StudioPrimaryButtonStyle())
            .disabled(!store.isLive || !library.isLive || !store.localStart.isLaunchSupported
                      || selected == nil || selected.map { modelIssue($0) != nil } == true)
            .help("Start a local session using the selected installed model. Your draft will not be sent.")
    }

    @ViewBuilder
    private var libraryAction: some View {
        if let onOpenModels {
            Button("Open Library", action: onOpenModels)
                .buttonStyle(.borderless)
                .foregroundStyle(StudioPalette.accent)
        }
    }

    private var emptyMessage: String {
        switch library.catalogState {
        case .loading: "Finding models on this Mac…"
        case .offline: "Your model library needs a refresh."
        case .available: "Choose a model in Library to get started."
        }
    }

    private var selectionIssue: String? {
        if let selected { return modelIssue(selected) }
        if let preferred = library.selectedModel, preferred.isInstalled {
            return modelIssue(preferred)
        }
        if !installed.isEmpty, installed.allSatisfy({ modelIssue($0) != nil }) {
            return installed.first.flatMap(modelIssue)
        }
        return nil
    }

    private func modelIssue(_ model: ModelSummary) -> String? {
        do {
            // Match the existing selector: fixtures may select, never launch.
            try LocalAPIStartPreflight.validateModel(modelID: model.id, models: [model], modelsAreLive: true)
            return nil
        } catch { return error.localizedDescription }
    }
}
