import Foundation
import Observation
import ProviderCoreFoundation

@MainActor
@Observable
final class AvailabilityStore {
    private(set) var loadState: AvailabilityStoreLoadState
    private(set) var savedPolicy: AvailabilityPolicy?
    private(set) var draft: AvailabilityPolicy?
    private(set) var runtime: AvailabilityRuntimeSnapshot?
    private(set) var saveState: AvailabilitySaveAndRestartState = .idle
    /// A confirmed or possibly committed write survives draft edits and result
    /// dismissal. A verified fresh daemon generation can clear the warning.
    private(set) var partialSaveRequiresRestart = false
    private(set) var savedPolicyNeedsReconciliation = false
    private(set) var isRefreshing = false

    /// Live context: nil for fixture-backed preview stores.
    private let live: LiveContext?

    private let previewSaveShouldFail: Bool
    private var restartCheckpoint: AvailabilityRestartCheckpoint?

    struct LiveContext: Sendable {
        let cli: any AvailabilityCLIRunning
        let stateFileURL: URL
        let now: @Sendable () -> Date
        let readProcessIdentity: @Sendable (Int32) -> ProcessIdentity?
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
    init(
        cli: any AvailabilityCLIRunning,
        stateFileURL: URL = DaemonStateFile.path(),
        now: @escaping @Sendable () -> Date = { Date() },
        readProcessIdentity: @escaping @Sendable (Int32) -> ProcessIdentity? = { ProcessIdentity.read(pid: $0) }
    ) {
        live = LiveContext(cli: cli, stateFileURL: stateFileURL, now: now,
                           readProcessIdentity: readProcessIdentity)
        loadState = .loading
        savedPolicy = nil
        draft = nil
        runtime = AvailabilityRuntimeSnapshot.readStateFile(stateFileURL)
        saveState = .idle
        previewSaveShouldFail = false
    }

    /// True when this store drives real CLI/config I/O (real launches);
    /// false for deterministic preview fixtures. Views use it to pick
    /// preview-flavored vs. live copy.
    var isLive: Bool { live != nil }

    /// Live-only: a policy was written but the daemon applies config only on
    /// launch. A partial save also keeps this visible after the editor closes.
    var requiresRestart: Bool {
        if partialSaveRequiresRestart { return true }
        if case .savedRequiresRestart = saveState { return true }
        return false
    }

    var validation: AvailabilityPolicyValidation? {
        draft?.validation
    }

    var hasUnsavedChanges: Bool {
        guard let draft, let savedPolicy else { return false }
        if savedPolicyNeedsReconciliation { return true }
        if isLive {
            return scheduleShapeDiffers(draft: draft, saved: savedPolicy)
                || draft.idleUnloadMinutes != savedPolicy.idleUnloadMinutes
        }
        return draft != savedPolicy
    }

    var canSaveAndRestart: Bool {
        guard let draft else { return false }
        return !saveState.isSaving && !isRefreshing && draft.validation.isValid && hasUnsavedChanges
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
        // An unverified snapshot cannot truthfully replace the user's draft.
        guard !savedPolicyNeedsReconciliation, let savedPolicy else { return }
        draft = savedPolicy
        saveState = .idle
    }

    func dismissSaveResult() {
        guard !saveState.isSaving else { return }
        saveState = .idle
    }

    /// Heartbeat updates only trigger config I/O after a verified new process
    /// could have applied a pending save. Repeated old heartbeats are cheap.
    func refreshAfterObservedRestart() async {
        guard let live, let checkpoint = restartCheckpoint,
              !isRefreshing, !saveState.isSaving,
              let state = DaemonStateFile.read(from: live.stateFileURL),
              checkpoint.confirmsRestart(state: state, now: live.now(),
                                         readIdentity: live.readProcessIdentity) else { return }
        await refresh()
    }

    /// Live only: (re)read the persisted schedule + daemon posture. Safe for
    /// fixture stores (no-op) so views can call it unconditionally.
    func refresh() async {
        guard let live, !saveState.isSaving, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if partialSaveRequiresRestart || savedPolicyNeedsReconciliation || restartCheckpoint != nil {
            await reconcilePartialSave(using: live)
            if savedPolicyNeedsReconciliation {
                partialSaveRequiresRestart = true
                saveState = .failed(message: "The saved availability could not be verified. "
                    + "Your changes are still here; reload availability before restarting.")
            } else {
                clearRestartWarningIfVerified(using: live)
                // Keep a normal successful-save banner until runtime verifies it.
                if partialSaveRequiresRestart { saveState = .idle }
            }
            return
        }
        let hadPolicy = savedPolicy != nil
        let preserveDraft = hasUnsavedChanges
        let draftBeforeRead = draft
        do {
            let payload = try await live.cli.fetchSchedule()
            runtime = AvailabilityRuntimeSnapshot.readStateFile(live.stateFileURL)
            switch AvailabilityPersistence.resolve(payload) {
            case .policy(let policy):
                savedPolicy = policy
                if !preserveDraft, draft == draftBeforeRead { draft = policy }
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
            runtime = AvailabilityRuntimeSnapshot.readStateFile(live.stateFileURL)
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
    /// Failed preview saves leave the policy and draft intact. Live partial
    /// saves reconcile the persisted policy while retaining the edited draft.
    ///
    /// On a live store the same action performs the real persist via
    /// `darkbloom config set schedule ...` and ends in
    /// `.savedRequiresRestart` — config is written, nothing is restarted.
    func saveAndRestartPreview(at date: Date = .now) async {
        guard !saveState.isSaving, !isRefreshing, let draft else { return }
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

        let rewriteUnverifiedPolicy = savedPolicyNeedsReconciliation
        let previousPolicy = savedPolicy
        let alreadyRequiresRestart = requiresRestart || restartCheckpoint != nil
        // A new attempted write cannot borrow evidence from an earlier save.
        restartCheckpoint = nil
        var confirmedWrite = false
        saveState = .saving
        do {
            if rewriteUnverifiedPolicy || scheduleShapeDiffers(draft: draft, saved: savedPolicy) {
                try await live.cli.apply(
                    arguments: AvailabilityScheduleCLIArguments.scheduleArguments(for: draft))
                confirmedWrite = true
                // Record the acknowledged schedule before the second command:
                // a failed idle write must never restore the old schedule.
                var persisted = savedPolicy ?? draft
                persisted.mode = draft.mode
                persisted.windows = draft.windows
                savedPolicy = persisted
            }
            if rewriteUnverifiedPolicy || draft.idleUnloadMinutes != savedPolicy?.idleUnloadMinutes {
                try await live.cli.apply(
                    arguments: AvailabilityScheduleCLIArguments.idleUnloadArguments(for: draft))
            }
            savedPolicy = draft
            savedPolicyNeedsReconciliation = false
            partialSaveRequiresRestart = false
            restartCheckpoint = AvailabilityRestartCheckpoint(policy: draft, verifiedAt: live.now())
            loadState = .ready(lastUpdated: date)
            runtime = AvailabilityRuntimeSnapshot.readStateFile(live.stateFileURL)
            saveState = .savedRequiresRestart(at: date)
        } catch {
            // Every invoked apply can commit before it reports failure, even
            // the first/only command. An unacknowledged write is uncertain,
            // never proof that the previous policy is still on disk.
            partialSaveRequiresRestart = true
            await reconcilePartialSave(using: live)
            if !confirmedWrite, !alreadyRequiresRestart, !savedPolicyNeedsReconciliation,
               let previousPolicy, let savedPolicy,
               AvailabilityPersistence.sameConfiguration(previousPolicy, savedPolicy) {
                partialSaveRequiresRestart = false
                restartCheckpoint = nil
            }
            let outcome = confirmedWrite
                ? "A configuration write succeeded, but Darkbloom could not finish saving availability"
                : "Darkbloom could not confirm the configuration write; it may have been saved"
            let reconciliation = savedPolicyNeedsReconciliation
                ? "The complete saved configuration could not be verified; reload availability before restarting."
                : "The saved configuration has been reloaded."
            let restart = partialSaveRequiresRestart
                ? " Saved changes require a provider restart to take effect." : ""
            saveState = .failed(message: "\(outcome) (\(error.localizedDescription)). "
                + "\(reconciliation) Your changes are still here.\(restart)")
        }
    }

    /// One read through the existing timeout-bounded CLI contract. Never call
    /// refresh here: its initial-load fallback can invent defaults or erase edits.
    private func reconcilePartialSave(using live: LiveContext) async {
        savedPolicyNeedsReconciliation = true
        do {
            let policy = try await AvailabilityPersistence.reconcile(using: live.cli)
            if restartCheckpoint.map({ AvailabilityPersistence.sameConfiguration($0.policy, policy) }) != true {
                // Changed or previously unverified config needs a generation
                // newer than THIS read; a running process may have loaded less.
                restartCheckpoint = AvailabilityRestartCheckpoint(policy: policy, verifiedAt: live.now())
            }
            savedPolicy = policy
            savedPolicyNeedsReconciliation = false
            loadState = .ready(lastUpdated: live.now())
        } catch {
            // A failed read breaks continuity with the last confirmed policy.
            restartCheckpoint = nil
            let lastUpdated: Date
            switch loadState {
            case .ready(let date), .stale(let date, _): lastUpdated = date
            case .loading, .malformed: lastUpdated = .now
            }
            loadState = .stale(
                lastUpdated: lastUpdated,
                message: "Availability may have changed, but the complete configuration could not be verified "
                    + "(\(error.localizedDescription)). Showing the last confirmed values. "
                    + "Your draft is retained; reload availability before discarding it or restarting.")
        }
        runtime = AvailabilityRuntimeSnapshot.readStateFile(live.stateFileURL)
    }

    /// Called only after refresh has re-read the complete saved configuration.
    /// A restart request, stale heartbeat, reused PID, or different policy is
    /// insufficient. Draft edits remain untouched when the warning clears.
    private func clearRestartWarningIfVerified(using live: LiveContext) {
        guard !savedPolicyNeedsReconciliation, let checkpoint = restartCheckpoint,
              let savedPolicy,
              AvailabilityPersistence.sameConfiguration(checkpoint.policy, savedPolicy),
              let state = DaemonStateFile.read(from: live.stateFileURL),
              checkpoint.confirmsRestart(state: state, now: live.now(),
                                         readIdentity: live.readProcessIdentity) else { return }
        partialSaveRequiresRestart = false
        restartCheckpoint = nil
        if case .savedRequiresRestart = saveState { saveState = .idle }
        if case .failed = saveState { saveState = .idle }
    }

    /// The editable part of a policy (mode + windows), for deciding whether
    /// a save must rewrite the `[schedule]` section at all.
    private func scheduleShapeDiffers(draft: AvailabilityPolicy, saved: AvailabilityPolicy?) -> Bool {
        guard let saved else { return true }
        // CLI reads regenerate window IDs; those IDs and inactive windows
        // are editor metadata, not differences in persisted configuration.
        return AvailabilityScheduleCLIArguments.scheduleArguments(for: draft)
            != AvailabilityScheduleCLIArguments.scheduleArguments(for: saved)
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
