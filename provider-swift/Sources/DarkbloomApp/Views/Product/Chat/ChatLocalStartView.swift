import SwiftUI

/// Chat presents the shared local-session controller. All launch eligibility,
/// provenance, conflict checks and process ownership remain in LocalAPIStore.
struct ChatLocalStartView: View {
    let store: LocalAPIStore
    let library: ModelLibraryStore
    let chat: ChatStore
    let providerSnapshot: ProviderSnapshot?
    let onOpenModels: (() -> Void)?
    let onOpenDiagnostics: (() -> Void)?
    let onOpenProviderControls: (() -> Void)?
    let onProcessChange: @MainActor () -> Void
    let onRefreshConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.localStart.hasActiveSession {
                sessionControls
            } else if chat.connection != .available {
                if let conflict = store.startConflict(providerSnapshot: providerSnapshot) {
                    conflictControls(conflict)
                } else {
                    ChatLocalModelPicker(
                        store: store, library: library,
                        onOpenModels: onOpenModels,
                        onOpenDiagnostics: onOpenDiagnostics,
                        onStart: startSelectedModel,
                        onSelectModel: { ChatModelHandoff.select($0, in: chat) }
                    )
                }
            }

            if case .failed(let error) = store.localStart.state {
                ChatLocalStartDetails(summary: ChatLocalStartCopy.failure(error), detail: error.localizedDescription)
            } else if case .cancelled = store.localStart.state, chat.connection != .available {
                Text("Start cancelled. Your draft is still here.")
                    .foregroundStyle(StudioPalette.secondaryInk)
            }

            if !store.localStart.hasActiveSession,
               case .unavailable(let failure) = chat.connection,
               failure == .untrustedDiscovery {
                ChatLocalStartDetails(summary: "Previous connection details", detail: failure.detail)
            }
        }
        .font(DarkbloomTheme.chivo(12))
        .foregroundStyle(StudioPalette.secondaryInk)
    }

    private var sessionControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                sessionLabel
                Spacer(minLength: 12)
                sessionActions
            }
            VStack(alignment: .leading, spacing: 10) {
                sessionLabel
                sessionActions
            }
        }
    }

    private var sessionLabel: some View {
        HStack(spacing: 8) {
            if store.localStart.state.isWaiting || store.localStart.state == .cancelling {
                ProgressView().controlSize(.small)
            }
            Text(sessionSummary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var sessionSummary: String {
        if case .ready(let runningID) = store.localStart.state,
           let selectedID = store.selectedLocalModelID, selectedID != runningID {
            let name = library.models.first { $0.id == selectedID }?.displayName ?? selectedID
            return "End the current session to start \(name). Your conversation stays here."
        }
        return ChatLocalStartCopy.session(store.localStart.state, models: library.models)
    }

    private var sessionActions: some View {
        HStack(spacing: 16) {
            if case .failed = store.localStart.state {
                Button("Check again") { store.localStart.checkAgain() }
                if let onOpenDiagnostics {
                    Button("Diagnostics", action: onOpenDiagnostics)
                }
            }
            Button(store.localStart.state.isWaiting ? "Cancel start" : "End session") {
                store.localStart.cancel()
            }
            .disabled(store.localStart.state == .cancelling)
            .help("Stop only the local session started by this app")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(StudioPalette.accent)
    }

    private func conflictControls(_ conflict: LocalAPIStartConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Text(ChatLocalStartCopy.conflict(conflict))
                    Spacer(minLength: 8)
                    connectionActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(ChatLocalStartCopy.conflict(conflict))
                    connectionActions
                }
            }
            ChatLocalStartDetails(summary: "Connection details", detail: conflict.message)
        }
    }

    private var connectionActions: some View {
        HStack(spacing: 16) {
            Button("Check connection", action: onRefreshConnection)
                .disabled(chat.isResponding || chat.connection == .checking)
            if let onOpenProviderControls {
                Button("Provider controls", action: onOpenProviderControls)
            } else if let onOpenDiagnostics {
                Button("Diagnostics", action: onOpenDiagnostics)
            }
            if chat.connection == .unavailable(.noModels), let onOpenModels {
                Button("Open Library", action: onOpenModels)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(StudioPalette.accent)
    }

    private func startSelectedModel() {
        guard let modelID = store.selectedLocalModelID else { return }
        // Only this explicit button action may cross the launch boundary.
        // The store re-runs preflight immediately before the owned CLI starts.
        store.startLocalOnly(
            modelID: modelID,
            models: library.models,
            modelsAreLive: library.isLive,
            providerSnapshot: providerSnapshot,
            onProcessChange: onProcessChange
        )
        if store.localStart.hasActiveSession {
            chat.selectedModelID = modelID
        }
    }
}
