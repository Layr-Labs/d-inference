import Observation

struct DiagnosticActionPresentation {
    let title: String
    var disabledReason: String?

    var isEnabled: Bool { disabledReason == nil }
}

/// The shell supplies its existing navigation and guarded provider request
/// entry point. Diagnostics never receives a provider lifecycle executor.
@MainActor
struct DiagnosticActionCallbacks {
    let isPreview: Bool
    let restartUnavailableReason: String?
    let onContinueSetup: () -> Void
    let requestProviderAction: (ProviderAction) -> Void
    let openModelLibrary: (String?) -> Void
    let openNetworkSettings: () throws -> Void

    static func restartUnavailableReason(
        providerStore: ProviderStore,
        needsSetup: Bool,
        hasActiveLocalSession: Bool
    ) -> String? {
        if hasActiveLocalSession {
            return "End the local session in Studio before restarting the network provider."
        }
        if needsSetup {
            return "Finish network sharing setup before restarting the provider."
        }
        if !providerStore.canPerform(.restart) {
            return "Wait for the current provider action to finish before restarting."
        }
        return nil
    }
}

/// Owned by the shell so deferred actions survive the diagnostics sheet.
/// Consume them from sheet.onDismiss, after navigation or a confirmation can
/// be presented on the parent. Eligibility is checked again at that boundary.
@MainActor
@Observable
final class DiagnosticActionDispatcher {
    private(set) var pendingFix: DiagnosticFix?

    func presentation(
        for fix: DiagnosticFix,
        in store: DiagnosticsStore,
        callbacks: DiagnosticActionCallbacks
    ) -> DiagnosticActionPresentation {
        let isLive = store.isLive && !callbacks.isPreview
        let route = route(for: fix, in: store)
        let title = isLive ? route.title : "Preview Fix"
        let reason: String?
        if store.isScanning {
            reason = "Wait for the system check to finish."
        } else if pendingFix != nil {
            reason = "Closing the system check…"
        } else if !store.report.prioritizedFixes.contains(fix) {
            reason = "Run the system check again to review the current next steps."
        } else if isLive, case .restart = route {
            reason = callbacks.restartUnavailableReason
        } else {
            reason = nil
        }
        return DiagnosticActionPresentation(title: title, disabledReason: reason)
    }

    /// Returns a fix only when the sheet should display manual guidance or
    /// a preview simulation. Live product actions dispatch after dismissal;
    /// the update check stays in the sheet and uses the existing doctor scan.
    func open(
        _ fix: DiagnosticFix,
        in store: DiagnosticsStore,
        callbacks: DiagnosticActionCallbacks,
        dismiss: () -> Void
    ) -> DiagnosticFix? {
        guard presentation(for: fix, in: store, callbacks: callbacks).isEnabled,
              store.triggerFix(id: fix.id) != nil else { return nil }
        guard store.isLive, !callbacks.isPreview else { return fix }

        switch route(for: fix, in: store) {
        case .guidance:
            return fix
        case .updates:
            store.startScan()
        case .setup, .restart, .models, .networkSettings:
            pendingFix = fix
            dismiss()
        }
        return nil
    }

    func didDismiss(
        store: DiagnosticsStore,
        callbacks: DiagnosticActionCallbacks
    ) throws {
        let fix = pendingFix
        // Clear before any callback, including one that changes the root view
        // or presents another sheet. Duplicate dismiss notifications are inert.
        pendingFix = nil
        store.clearSelectedFix()
        guard let fix, store.isLive, !callbacks.isPreview,
              presentation(for: fix, in: store, callbacks: callbacks).isEnabled else { return }

        switch route(for: fix, in: store) {
        case .setup:
            callbacks.onContinueSetup()
        case .restart:
            callbacks.requestProviderAction(.restart)
        case .models(let modelID):
            callbacks.openModelLibrary(modelID)
        case .networkSettings:
            try callbacks.openNetworkSettings()
        case .updates, .guidance:
            break
        }
    }

    private enum Route {
        case setup, restart, networkSettings, updates
        case models(String?)
        case guidance(instructions: Bool)

        var title: String {
            switch self {
            case .setup: "Finish Setup"
            case .restart: "Restart"
            case .models: "Open Model Library"
            case .networkSettings: "Network Settings"
            case .updates: "Check for Updates"
            case .guidance(let instructions): instructions ? "View Instructions" : "View Guidance"
            }
        }
    }

    private func route(for fix: DiagnosticFix, in store: DiagnosticsStore) -> Route {
        let check = store.report.checks.first { $0.fix?.id == fix.id }
        // These sections must not become lifecycle actions because their
        // manual advice happens to mention restarting after recovery/install.
        if check?.section == .security { return .guidance(instructions: true) }
        if check?.section == .version { return .updates }
        // Existing schema-1 doctor IDs; no model ID is supplied in structured
        // fields here, so open the library with its current selection intact.
        if check?.id == "traffic.model-fits-in-ram" || check?.id == "runtime.recent-model-load" {
            return .models(nil)
        }
        switch fix.action {
        case .openEnrollment: return .setup
        case .restartProvider: return .restart
        case .redownloadModel(let modelID): return .models(modelID)
        case .openNetworkSettings: return .networkSettings
        case .checkForUpdates: return .updates
        case .openRecoveryInstructions: return .guidance(instructions: true)
        case .openSupport: return .guidance(instructions: false)
        }
    }
}
