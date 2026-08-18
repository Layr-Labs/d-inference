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

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                ProductSectionHeader(
                    "Try it",
                    detail: "OpenAI-compatible chat completions"
                )

                Picker("Example", selection: $store.selectedExample) {
                    ForEach(LocalAPICodeExample.allCases) { example in
                        Text(example.title).tag(example)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            catalogContent
        }
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var catalogContent: some View {
        switch endpoint.modelCatalog {
        case .available(let modelIDs) where !modelIDs.isEmpty:
            codeContent

        case .available:
            guidanceRow(
                icon: "shippingbox",
                title: "A model is required before you can try the endpoint.",
                detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
            ) {
                Button("Open Models", action: onOpenModels)
            }

        case .loading:
            guidanceRow(
                icon: "ellipsis.circle",
                title: "Checking available models…",
                detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
            ) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking the available model catalog")
            }

        case .failed:
            guidanceRow(
                icon: "exclamationmark.triangle.fill",
                title: "The available-model catalog is out of reach.",
                detail: LocalAPIPresentation.availableModelDetail(endpoint.modelCatalog)
            ) {
                HStack(spacing: 10) {
                    Button("Check Again", action: onRetryCatalog)
                        .buttonStyle(.borderedProminent)
                    Button("Open Diagnostics", action: onOpenDiagnostics)
                }
            }
        }
    }

    @ViewBuilder
    private var codeContent: some View {
        if let code = store.text(for: .code(store.selectedExample)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(store.selectedExample.title.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        onCopy(.code(store.selectedExample))
                    } label: {
                        Label(
                            store.lastCopiedItem == .code(store.selectedExample) ? "Copied" : "Copy",
                            systemImage: store.lastCopiedItem == .code(store.selectedExample)
                                ? "checkmark"
                                : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)

                Divider()

                ScrollView(.horizontal) {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(14)
                }
                .accessibilityLabel("\(store.selectedExample.title) example")
            }
            .background(ProductPalette.surface)
            .overlay { Rectangle().stroke(ProductPalette.stroke, lineWidth: 1) }

            if endpoint.requiresAuthentication {
                Text("Export OPENAI_API_KEY with the sample key before running this example. The key is referenced by name and is never embedded in copied code.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func guidanceRow<Actions: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(ProductPalette.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
        .padding(.vertical, 12)
    }
}
