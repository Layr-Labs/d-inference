import SwiftUI

struct AvailabilityScheduleEditor: View {
    let store: AvailabilityStore
    let providerIsServing: Bool
    let onCancel: () -> Void
    let onSaved: () -> Void

    @State private var showingServingConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    previewNotice

                    if let policy = store.draft {
                        AvailabilityEditorPlanSection(store: store, policy: policy)
                        sectionDivider

                        if policy.mode == .scheduled {
                            AvailabilityWindowsSection(store: store, policy: policy)
                            sectionDivider
                        }

                        AvailabilityEditorIdleUnloadSection(store: store, policy: policy)
                        AvailabilityEditorValidationSection(store: store, policy: policy)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }

            Divider()
            editorFooter
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 620, idealHeight: 700)
        .background(ProductPalette.pageBackground)
        .interactiveDismissDisabled(store.hasUnsavedChanges || store.saveState.isSaving)
        .alert("Save schedule while this Mac is serving?", isPresented: $showingServingConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(store.isLive ? "Save Schedule" : "Save & Restart") {
                performPreviewSave()
            }
        } message: {
            if store.isLive {
                Text("Saving rewrites the provider schedule now; it takes effect on the next provider restart, which would interrupt current inference.")
            } else {
                Text("A real restart would interrupt current inference. This UI preview will save sample state only; it will not change a config file, interrupt work, or restart the provider.")
            }
        }
    }

    private var editorHeader: some View {
        HStack(alignment: .center, spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit availability")
                    .font(DarkbloomTheme.chivo(23))
                    .tracking(-0.45)
                    .accessibilityAddTraits(.isHeader)
                Text("Set when the network provider may connect and when idle models may unload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.hasUnsavedChanges {
                Text("UNSAVED CHANGES")
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(DarkbloomTheme.accent)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var previewNotice: some View {
        AvailabilityInlineNotice(
            title: store.isLive ? "Writes this Mac’s provider config" : "UI preview only",
            detail: store.isLive
                ? "Save updates the schedule in the provider configuration. The running provider keeps its current plan until you restart it."
                : "Save & Restart changes the sample shown in this app. No provider configuration or process will be changed.",
            systemImage: store.isLive ? "externaldrive.connected.to.line.below" : "rectangle.and.pencil.and.ellipsis",
            tint: DarkbloomTheme.accent
        )
        .padding(.bottom, 22)
    }

    private var editorFooter: some View {
        HStack(spacing: 12) {
            if let draft = store.draft, !store.hasUnsavedChanges {
                Label("No changes to save", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No changes to save for \(AvailabilityPresentation.planTitle(draft.mode))")
            }

            Spacer()

            Button("Cancel") {
                store.discardDraftChanges()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(store.saveState.isSaving)

            Button {
                requestPreviewSave()
            } label: {
                if store.saveState.isSaving {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving…")
                    }
                    .frame(minWidth: 122)
                } else {
                    Label("Save & Restart", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!store.canSaveAndRestart)
            .help(store.isLive
                ? "Writes the provider configuration; applies on the next provider restart"
                : "UI preview only — no config file or process will change")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 24)
    }

    private func requestPreviewSave() {
        if providerIsServing {
            showingServingConfirmation = true
        } else {
            performPreviewSave()
        }
    }

    private func performPreviewSave() {
        Task { @MainActor in
            await store.saveAndRestartPreview()

            switch store.saveState {
            case .savedAndRestarted:
                AccessibilityNotification.Announcement(
                    "Availability preview saved. No configuration or provider process changed."
                ).post()
                onSaved()
            case .savedRequiresRestart:
                AccessibilityNotification.Announcement(
                    "Schedule saved to the provider configuration. Restart the provider to apply it."
                ).post()
                onSaved()
            case .failed(let message):
                AccessibilityNotification.Announcement(message).post()
            case .validationFailed:
                AccessibilityNotification.Announcement(
                    "The availability schedule has validation errors."
                ).post()
            case .idle, .saving:
                break
            }
        }
    }
}
