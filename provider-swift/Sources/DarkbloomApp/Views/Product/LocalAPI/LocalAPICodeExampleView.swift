import SwiftUI

struct LocalAPICodeExampleView: View {
    let store: LocalAPIStore
    let endpoint: LocalAPIEndpointSnapshot
    let onCopy: (LocalAPICopyItem) -> Void
    let onOpenModels: () -> Void
    let onRetryCatalog: () -> Void
    let onOpenDiagnostics: () -> Void

    var body: some View {
        @Bindable var store = store

        LocalAPIDisclosure("Code examples") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Picker("Example", selection: $store.selectedExample) {
                        ForEach(LocalAPICodeExample.allCases) { example in
                            Text(example.title).tag(example)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 168)

                    Spacer(minLength: 0)
                    if endpoint.availableModelIDs?.isEmpty == false,
                       store.text(for: .code(store.selectedExample)) != nil {
                        LocalAPICopyButton(
                            title: "Copy example", item: .code(store.selectedExample),
                            copiedItem: store.lastCopiedItem, onCopy: onCopy
                        )
                    }
                }

                catalogContent
            }
        }
    }

    @ViewBuilder
    private var catalogContent: some View {
        switch endpoint.modelCatalog {
        case .available(let modelIDs) where !modelIDs.isEmpty:
            codeContent
        case .available:
            guidanceRow(
                title: "This endpoint has no compatible models.",
                detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
            ) {
                Button("Open Library", action: onOpenModels)
            }
        case .loading:
            guidanceRow(
                title: "Checking available models…",
                detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
            ) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking the available model catalog")
            }
        case .failed:
            guidanceRow(
                title: "The model list is unavailable.",
                detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
            ) {
                HStack(spacing: 14) {
                    Button("Check again", action: onRetryCatalog)
                        .buttonStyle(StudioPrimaryButtonStyle())
                    Button("Diagnostics", action: onOpenDiagnostics)
                }
            }
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        if let code = store.text(for: .code(store.selectedExample)) {
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(StudioPalette.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(16)
            }
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("\(store.selectedExample.title) example")

            if endpoint.requiresAuthentication {
                Text(store.isLive
                    ? "Set OPENAI_API_KEY to your API key. Copied examples never include the key."
                    : "Set OPENAI_API_KEY to the sample key. Copied examples never include the key.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func guidanceRow<Actions: View>(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioPalette.ink)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
    }
}
