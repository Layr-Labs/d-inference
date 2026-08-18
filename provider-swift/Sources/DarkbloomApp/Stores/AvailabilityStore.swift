import Foundation
import Observation

enum AvailabilityFixture: String, CaseIterable, Sendable {
    case always
    case scheduledActive = "scheduled-active"
    case scheduledOff = "scheduled-off"
    case pausedScheduled = "paused-scheduled"
    case serving
    case loading
    case stale
    case malformed
    case saveFailure = "save-failure"
}

enum AvailabilityStoreLoadState: Equatable, Sendable {
    case loading
    case ready(lastUpdated: Date)
    case stale(lastUpdated: Date, message: String)
    case malformed(message: String, issues: [AvailabilityPolicySourceIssue])
}

enum AvailabilitySaveAndRestartState: Equatable, Sendable {
    case idle
    case saving
    case savedAndRestarted(at: Date)
    case validationFailed(issues: [AvailabilityPolicyValidationIssue])
    case failed(message: String)

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}

@MainActor
@Observable
final class AvailabilityStore {
    private(set) var loadState: AvailabilityStoreLoadState
    private(set) var savedPolicy: AvailabilityPolicy?
    private(set) var draft: AvailabilityPolicy?
    private(set) var runtime: AvailabilityRuntimeSnapshot?
    private(set) var saveState: AvailabilitySaveAndRestartState = .idle

    private let previewSaveShouldFail: Bool

    init(fixture: AvailabilityFixture = .always) {
        let state = AvailabilityFixtures.make(fixture)
        loadState = state.loadState
        savedPolicy = state.policy
        draft = state.draft
        runtime = state.runtime
        saveState = state.initialSaveState
        previewSaveShouldFail = state.saveShouldFail
    }

    var validation: AvailabilityPolicyValidation? {
        draft?.validation
    }

    var hasUnsavedChanges: Bool {
        guard let draft, let savedPolicy else { return false }
        return draft != savedPolicy
    }

    var canSaveAndRestart: Bool {
        guard let draft else { return false }
        return !saveState.isSaving && draft.validation.isValid && hasUnsavedChanges
    }

    func setMode(_ mode: AvailabilityPolicyMode) {
        mutateDraft { $0.mode = mode }
    }

    func setIdleUnloadMinutes(_ minutes: Int) {
        mutateDraft { $0.idleUnloadMinutes = minutes }
    }

    func addWindow(_ window: AvailabilityWindow) {
        mutateDraft { $0.windows.append(window) }
    }

    func updateWindow(_ window: AvailabilityWindow) {
        mutateDraft { draft in
            guard let index = draft.windows.firstIndex(where: { $0.id == window.id }) else {
                return
            }
            draft.windows[index] = window
        }
    }

    func removeWindow(id: AvailabilityWindow.ID) {
        mutateDraft { draft in
            draft.windows.removeAll { $0.id == id }
        }
    }

    func replaceDraft(_ policy: AvailabilityPolicy) {
        guard savedPolicy != nil else { return }
        draft = policy
        clearCompletedSaveState()
    }

    func discardDraftChanges() {
        guard let savedPolicy else { return }
        draft = savedPolicy
        saveState = .idle
    }

    func dismissSaveResult() {
        guard !saveState.isSaving else { return }
        saveState = .idle
    }

    /// Deterministic UI-preview persistence seam. It models the required
    /// provider restart but performs no config I/O and launches no process.
    /// Failed saves leave both the persisted policy and edited draft intact so
    /// the user can correct or retry their work.
    func saveAndRestartPreview(at date: Date = .now) async {
        guard let draft else { return }
        let validation = draft.validation
        guard validation.isValid else {
            saveState = .validationFailed(issues: validation.issues)
            return
        }
        guard hasUnsavedChanges else {
            saveState = .idle
            return
        }

        saveState = .saving
        await Task.yield()

        if previewSaveShouldFail {
            saveState = .failed(
                message: "Darkbloom could not save the provider configuration. Your changes are still here."
            )
            return
        }

        savedPolicy = draft
        saveState = .savedAndRestarted(at: date)
    }

    private func mutateDraft(_ mutation: (inout AvailabilityPolicy) -> Void) {
        guard var draft else { return }
        mutation(&draft)
        self.draft = draft
        clearCompletedSaveState()
    }

    private func clearCompletedSaveState() {
        switch saveState {
        case .savedAndRestarted, .validationFailed:
            saveState = .idle
        case .idle, .saving, .failed:
            break
        }
    }
}
