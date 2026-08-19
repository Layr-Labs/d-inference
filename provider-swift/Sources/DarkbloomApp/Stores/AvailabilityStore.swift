import Foundation
import Observation
import ProviderCoreFoundation

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
    /// Live stores: the policy was written to the provider config, but the
    /// running daemon only parses its config at launch — nothing has applied
    /// yet. The view surfaces a restart banner (`AvailabilityStore.requiresRestart`).
    case savedRequiresRestart(at: Date)
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

    /// Live context: nil for fixture-backed preview stores.
    private let live: LiveContext?

    private let previewSaveShouldFail: Bool

    struct LiveContext: Sendable {
        let cli: any AvailabilityCLIRunning
        let stateFileURL: URL
    }

    init(fixture: AvailabilityFixture = .always) {
        let state = AvailabilityFixtures.make(fixture)
        loadState = state.loadState
        savedPolicy = state.policy
        draft = state.draft
        runtime = state.runtime
        saveState = state.initialSaveState
        live = nil
        previewSaveShouldFail = state.saveShouldFail
    }

    /// Live store: reads the persisted schedule via `darkbloom config get
    /// schedule --json` (resolve through the same resolver the fixtures use)
    /// and the daemon's schedule posture from `~/.darkbloom/daemon-state.json`.
    /// Writes persist via `darkbloom config set schedule ...` and surface a
    /// requires-restart banner — the store never restarts the provider itself.
    init(cli: any AvailabilityCLIRunning, stateFileURL: URL = DaemonStateFile.path()) {
        live = LiveContext(cli: cli, stateFileURL: stateFileURL)
        loadState = .loading
        savedPolicy = nil
        draft = nil
        runtime = Self.runtimeFromStateFile(stateFileURL)
        saveState = .idle
        previewSaveShouldFail = false
    }

    /// True when this store drives real CLI/config I/O (real launches);
    /// false for deterministic preview fixtures. Views use it to pick
    /// preview-flavored vs. live copy.
    var isLive: Bool { live != nil }

    /// Live-only: a policy was written but the daemon applies config only on
    /// launch. True until the banner is dismissed or the draft changes.
    var requiresRestart: Bool {
        if case .savedRequiresRestart = saveState { return true }
        return false
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

    /// Live only: (re)read the persisted schedule + daemon posture. Safe for
    /// fixture stores (no-op) so views can call it unconditionally.
    func refresh() async {
        guard let live else { return }
        let hadPolicy = savedPolicy != nil
        do {
            let payload = try await live.cli.fetchSchedule()
            let record = AvailabilityScheduleRecord(
                enabled: payload.enabled,
                windows: payload.windows.map {
                    AvailabilityScheduleWindowRecord(days: $0.days, start: $0.start, end: $0.end)
                }
            )
            runtime = Self.runtimeFromStateFile(live.stateFileURL)
            switch AvailabilityPolicyResolver.resolve(
                schedule: record,
                localTimeZone: .current,
                idleUnloadMinutes: payload.idleTimeoutMinutes
                    ?? AvailabilityPolicy.defaultIdleUnloadMinutes
            ) {
            case .policy(let policy):
                savedPolicy = policy
                draft = policy
                loadState = .ready(lastUpdated: .now)
            case .malformed(let issues):
                savedPolicy = nil
                draft = nil
                loadState = .malformed(
                    message: "The saved availability schedule needs repair before it can be shown or changed.",
                    issues: issues
                )
            }
        } catch {
            runtime = Self.runtimeFromStateFile(live.stateFileURL)
            if hadPolicy {
                // Keep the last good policy visible; the banner says the rest.
                loadState = .stale(
                    lastUpdated: .now,
                    message: "Showing the last known schedule; `darkbloom config` could not be reached."
                )
            } else if liveScheduleReported(runtime) {
                // A schedule EXISTS (the daemon says so) but its windows
                // cannot be reconstructed without the CLI — editing blind
                // would clobber it.
                savedPolicy = nil
                draft = nil
                loadState = .malformed(
                    message: "A schedule is active on this Mac, but Darkbloom could not read it. "
                        + "Check that the Darkbloom CLI is installed and up to date.",
                    issues: []
                )
            } else {
                // TOML-free fallback: no readable schedule anywhere ⇒
                // the documented "always available" default, with a banner
                // that the read path degraded rather than silently ready.
                let fallback = AvailabilityPolicy(mode: .wheneverRunning)
                savedPolicy = fallback
                draft = fallback
                loadState = .stale(
                    lastUpdated: .now,
                    message: fallbackMessage(for: error)
                        + " Showing the always-available default."
                )
            }
        }
    }

    /// Deterministic UI-preview persistence seam. It models the required
    /// provider restart but performs no config I/O and launches no process.
    /// Failed saves leave both the persisted policy and edited draft intact so
    /// the user can correct or retry their work.
    ///
    /// On a live store the same action performs the real persist via
    /// `darkbloom config set schedule ...` and ends in
    /// `.savedRequiresRestart` — config is written, nothing is restarted.
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

        guard let live else {
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
            return
        }

        saveState = .saving
        do {
            // Schedule shape first, then the idle knob: if the write is
            // interrupted, the visible policy (windows) is either fully old
            // or fully new before the auxiliary knob moves.
            if scheduleShapeDiffers(draft: draft, saved: savedPolicy) {
                try await live.cli.apply(
                    arguments: AvailabilityScheduleCLIArguments.scheduleArguments(for: draft))
            }
            if draft.idleUnloadMinutes != savedPolicy?.idleUnloadMinutes {
                try await live.cli.apply(
                    arguments: AvailabilityScheduleCLIArguments.idleUnloadArguments(for: draft))
            }
            savedPolicy = draft
            runtime = Self.runtimeFromStateFile(live.stateFileURL)
            saveState = .savedRequiresRestart(at: date)
        } catch {
            saveState = .failed(
                message: "Darkbloom could not save the provider configuration "
                    + "(\(error.localizedDescription)). Your changes are still here.")
        }
    }

    /// The editable part of a policy (mode + windows), for deciding whether
    /// a save must rewrite the `[schedule]` section at all.
    private func scheduleShapeDiffers(draft: AvailabilityPolicy, saved: AvailabilityPolicy?) -> Bool {
        guard let saved else { return true }
        return draft.mode != saved.mode || draft.windows != saved.windows
    }

    /// Does the daemon state file report a schedule posture (any mode)?
    private func liveScheduleReported(_ runtime: AvailabilityRuntimeSnapshot?) -> Bool {
        guard let runtime else { return false }
        return runtime.state == .scheduledOff
            || runtime.nextObservedTransitionAt != nil
    }

    /// One-line cause for the stale banner, mapped from the CLI error.
    private func fallbackMessage(for error: any Error) -> String {
        if let cliError = error as? AvailabilityCLIError,
           case .cliNotFound = cliError {
            return "The Darkbloom CLI is not installed."
        }
        return "Darkbloom could not read the saved schedule."
    }

    /// Map the daemon state file onto the store's runtime observation. The
    /// view additionally overlays the ProviderStore snapshot's process state;
    /// the irreplaceable payloads here are the schedule-driven
    /// `nextObservedTransitionAt` and the source timestamps.
    private static func runtimeFromStateFile(_ url: URL) -> AvailabilityRuntimeSnapshot? {
        guard let state = DaemonStateFile.read(from: url) else { return nil }
        let writtenAt = Date(timeIntervalSince1970: state.writtenAt)
        let posture = state.schedule

        let runtimeState: AvailabilityRuntimeState
        switch posture?.mode {
        case "scheduled-off":
            runtimeState = .scheduledOff
        default:
            if state.isStale(now: Date().timeIntervalSince1970) {
                runtimeState = .stale
            } else if state.inferenceActive {
                runtimeState = .serving
            } else {
                runtimeState = .available
            }
        }

        return AvailabilityRuntimeSnapshot(
            sampledAt: writtenAt,
            sourceUpdatedAt: writtenAt,
            state: runtimeState,
            nextObservedTransitionAt: posture?.nextChangeAtEpoch.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func mutateDraft(_ mutation: (inout AvailabilityPolicy) -> Void) {
        guard var draft else { return }
        mutation(&draft)
        self.draft = draft
        clearCompletedSaveState()
    }

    private func clearCompletedSaveState() {
        switch saveState {
        case .savedAndRestarted, .savedRequiresRestart, .validationFailed:
            saveState = .idle
        case .idle, .saving, .failed:
            break
        }
    }
}
