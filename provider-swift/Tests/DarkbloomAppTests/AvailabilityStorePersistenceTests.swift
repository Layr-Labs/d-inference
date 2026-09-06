import Foundation
import Testing
@testable import DarkbloomApp

@Suite("AvailabilityStore partial-write reconciliation")
@MainActor
struct AvailabilityStorePersistenceTests {
    private actor ScriptedCLI: AvailabilityCLIRunning {
        private var reads: [Result<AvailabilityCLISchedule, AvailabilityCLIError>]
        private var writes: [Result<Void, AvailabilityCLIError>]
        private(set) var readCount = 0
        private(set) var appliedArguments: [[String]] = []

        init(
            reads: [Result<AvailabilityCLISchedule, AvailabilityCLIError>],
            writes: [Result<Void, AvailabilityCLIError>]
        ) {
            self.reads = reads
            self.writes = writes
        }

        func fetchSchedule() async throws -> AvailabilityCLISchedule {
            readCount += 1
            guard !reads.isEmpty else {
                throw AvailabilityCLIError.invalidOutput("unexpected extra read")
            }
            return try reads.removeFirst().get()
        }

        func apply(arguments: [String]) async throws {
            appliedArguments.append(arguments)
            guard !writes.isEmpty else {
                throw AvailabilityCLIError.invalidOutput("unexpected extra write")
            }
            try writes.removeFirst().get()
        }
    }

    private static let writeError = AvailabilityCLIError.exited(1, message: "idle write failed")
    private static let initial = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 60)
    private static let scheduleArguments = ["config", "set", "schedule", "mon", "09:00-10:00"]
    private static let idleArguments = ["config", "set", "schedule", "idle-timeout-minutes", "120"]

    private static func persisted(idle: Int? = 60) -> AvailabilityCLISchedule {
        AvailabilityCLISchedule(
            enabled: true,
            windows: [.init(days: ["mon"], start: "09:00", end: "10:00")],
            idleTimeoutMinutes: idle
        )
    }

    private func editedStore(cli: ScriptedCLI) async throws -> AvailabilityStore {
        // No real CLI, config, or daemon state is accessed by these tests.
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("availability-persistence-\(UUID().uuidString)/daemon-state.json")
        let store = AvailabilityStore(cli: cli, stateFileURL: stateURL)
        await store.refresh()
        store.setMode(.scheduled)
        store.addWindow(AvailabilityWindow(
            id: "draft-window",
            days: [.monday],
            start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0)),
            end: try #require(AvailabilityTimeOfDay(hour: 10, minute: 0))))
        store.setIdleUnloadMinutes(120)
        return store
    }

    @Test("a failed second write rereads the saved policy without replacing the draft")
    func partialWriteReconciles() async throws {
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), .success(Self.persisted())],
            writes: [.success(()), .failure(Self.writeError)])
        let store = try await editedStore(cli: cli)
        let draft = store.draft

        await store.saveAndRestartPreview()

        #expect(await cli.readCount == 2)
        #expect(await cli.appliedArguments == [Self.scheduleArguments, Self.idleArguments])
        #expect(store.savedPolicy?.mode == .scheduled)
        #expect(store.savedPolicy?.windows.first?.id == "window-1")
        #expect(store.savedPolicy?.idleUnloadMinutes == 60)
        #expect(store.draft == draft)
        #expect(store.hasUnsavedChanges)
        #expect(store.canSaveAndRestart)
        #expect(store.requiresRestart)
        #expect(store.partialSaveRequiresRestart)
        #expect(!store.savedPolicyNeedsReconciliation)
        guard case .ready = store.loadState,
              case .failed(let message) = store.saveState else {
            Issue.record("Expected a reconciled partial save with the CLI failure still visible")
            return
        }
        #expect(message.contains("write succeeded"))
        #expect(message.contains("idle write failed"))
        #expect(message.contains("configuration has been reloaded"))
        #expect(message.contains("provider restart"))

        store.dismissSaveResult()
        #expect(store.saveState == .idle)
        #expect(store.requiresRestart)
        store.setIdleUnloadMinutes(90)
        #expect(store.requiresRestart)
        store.discardDraftChanges()
        #expect(store.draft == store.savedPolicy)
        #expect(store.savedPolicy?.mode == .scheduled)
        #expect(!store.hasUnsavedChanges)
        #expect(store.requiresRestart)
        #expect(store.partialSaveRequiresRestart)
    }

    @Test("retry after reconciliation only writes the remaining idle change")
    func retryWritesRemainingChange() async throws {
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), .success(Self.persisted())],
            writes: [.success(()), .failure(Self.writeError), .success(())])
        let store = try await editedStore(cli: cli)
        await store.saveAndRestartPreview()

        let date = Date(timeIntervalSince1970: 1_800_000_000)
        await store.saveAndRestartPreview(at: date)

        #expect(await cli.appliedArguments == [Self.scheduleArguments, Self.idleArguments, Self.idleArguments])
        #expect(await cli.readCount == 2)
        #expect(store.savedPolicy == store.draft)
        #expect(!store.hasUnsavedChanges)
        #expect(!store.savedPolicyNeedsReconciliation)
        #expect(!store.partialSaveRequiresRestart)
        #expect(store.requiresRestart)
        #expect(store.saveState == .savedRequiresRestart(at: date))
        #expect(store.loadState == .ready(lastUpdated: date))
    }

    @Test("a command may persist its idle value before reporting failure")
    func failedCommandAlreadyPersisted() async throws {
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), .success(Self.persisted(idle: 120))],
            writes: [.success(()), .failure(Self.writeError)])
        let store = try await editedStore(cli: cli)
        let draft = store.draft
        await store.saveAndRestartPreview()

        #expect(store.savedPolicy?.idleUnloadMinutes == 120)
        #expect(store.draft == draft)
        // The CLI regenerates window IDs; that must not manufacture unsaved edits.
        #expect(store.savedPolicy?.windows.first?.id != store.draft?.windows.first?.id)
        #expect(!store.hasUnsavedChanges)
        #expect(!store.canSaveAndRestart)
        #expect(store.requiresRestart)
        await store.saveAndRestartPreview()
        #expect(await cli.appliedArguments.count == 2)
        #expect(await cli.readCount == 2)
        #expect(store.requiresRestart)
    }

    enum ReconciliationFailure: CaseIterable, Sendable {
        case unreadable, malformed, missingIdle, invalidIdle
    }

    @Test("failed reconciliation keeps acknowledged writes and draft uncertainty visible",
          arguments: ReconciliationFailure.allCases)
    func failedReconciliation(_ failure: ReconciliationFailure) async throws {
        let recovery: Result<AvailabilityCLISchedule, AvailabilityCLIError>
        switch failure {
        case .unreadable:
            recovery = .failure(.timedOut(command: "config get schedule --json"))
        case .malformed:
            recovery = .success(AvailabilityCLISchedule(
                enabled: true, windows: [.init(days: ["mon"], start: "25:99", end: "10:00")],
                idleTimeoutMinutes: 60))
        case .missingIdle:
            recovery = .success(Self.persisted(idle: nil))
        case .invalidIdle:
            recovery = .success(Self.persisted(idle: -1))
        }
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), recovery],
            writes: [.success(()), .failure(Self.writeError), .success(()), .success(())])
        let store = try await editedStore(cli: cli)
        let draft = store.draft
        await store.saveAndRestartPreview()

        #expect(await cli.readCount == 2)
        #expect(store.savedPolicy?.mode == .scheduled)
        #expect(store.savedPolicy?.windows == draft?.windows)
        #expect(store.savedPolicy?.idleUnloadMinutes == 60)
        #expect(store.draft == draft)
        #expect(store.hasUnsavedChanges)
        #expect(store.savedPolicyNeedsReconciliation)
        #expect(store.requiresRestart)
        guard case .stale(_, let staleMessage) = store.loadState,
              case .failed(let message) = store.saveState else {
            Issue.record("Expected an explicitly unverified partial save")
            return
        }
        #expect(staleMessage.contains("last confirmed values"))
        #expect(message.contains("write succeeded"))
        #expect(message.contains("could not be verified"))
        #expect(message.contains("provider restart"))

        store.discardDraftChanges()
        #expect(store.draft == draft)
        store.dismissSaveResult()
        #expect(store.requiresRestart)
        // Even a draft equal to the confirmed snapshot cannot be called saved
        // while the result of the failed idle write remains unknown.
        store.setIdleUnloadMinutes(60)
        #expect(store.draft == store.savedPolicy)
        #expect(store.hasUnsavedChanges)
        #expect(store.canSaveAndRestart)

        await store.saveAndRestartPreview()
        #expect(await cli.appliedArguments == [
            Self.scheduleArguments, Self.idleArguments, Self.scheduleArguments,
            ["config", "set", "schedule", "idle-timeout-minutes", "60"],
        ])
        #expect(await cli.readCount == 2)
        #expect(!store.savedPolicyNeedsReconciliation)
        #expect(!store.hasUnsavedChanges)
        #expect(store.requiresRestart)
        guard case .ready = store.loadState else {
            Issue.record("A successful retry must clear the unverified snapshot warning")
            return
        }
    }

    @Test("refresh can reconcile an uncertain save while retaining the full draft")
    func refreshReconcilesRetainingDraft() async throws {
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), .failure(.invalidOutput("read failed")),
                    .success(Self.persisted())],
            writes: [.success(()), .failure(Self.writeError)])
        let store = try await editedStore(cli: cli)
        let draft = store.draft
        await store.saveAndRestartPreview()
        #expect(store.savedPolicyNeedsReconciliation)

        await store.refresh()
        #expect(await cli.readCount == 3)
        #expect(await cli.appliedArguments.count == 2)
        #expect(store.savedPolicy?.mode == .scheduled)
        #expect(store.savedPolicy?.idleUnloadMinutes == 60)
        #expect(store.draft == draft)
        #expect(!store.savedPolicyNeedsReconciliation)
        #expect(store.hasUnsavedChanges)
        #expect(store.requiresRestart)
        #expect(store.saveState == .idle)
    }

    @Test("a first-write failure rereads disk and never attempts the second write")
    func firstWriteFailure() async throws {
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), .success(Self.initial)],
            writes: [.failure(.exited(1, message: "schedule write failed"))])
        let store = try await editedStore(cli: cli)
        let original = store.savedPolicy
        let draft = store.draft
        await store.saveAndRestartPreview()

        #expect(await cli.readCount == 2)
        #expect(await cli.appliedArguments == [Self.scheduleArguments])
        #expect(store.savedPolicy == original)
        #expect(store.draft == draft)
        #expect(store.hasUnsavedChanges)
        #expect(!store.requiresRestart)
        #expect(!store.savedPolicyNeedsReconciliation)
    }

    enum FirstWriteOutcome: CaseIterable, Equatable, Sendable {
        case committed, unchanged, unreadable
    }

    @Test("failed first and idle-only writes reconcile without losing the draft",
          arguments: [false, true], FirstWriteOutcome.allCases)
    func failedInvokedWrite(idleOnly: Bool, outcome: FirstWriteOutcome) async throws {
        var committed = idleOnly ? Self.initial : Self.persisted()
        if idleOnly { committed.idleTimeoutMinutes = 120 }
        let recovery: Result<AvailabilityCLISchedule, AvailabilityCLIError>
        switch outcome {
        case .committed: recovery = .success(committed)
        case .unchanged: recovery = .success(Self.initial)
        case .unreadable: recovery = .failure(.invalidOutput("readback failed"))
        }
        let cli = ScriptedCLI(reads: [.success(Self.initial), recovery],
                              writes: [.failure(.timedOut(command: "config set schedule"))])
        let store = try await editedStore(cli: cli)
        if idleOnly { store.setMode(.wheneverRunning) }
        let draft = store.draft
        await store.saveAndRestartPreview()

        #expect(await cli.readCount == 2)
        #expect(await cli.appliedArguments == [idleOnly ? Self.idleArguments : Self.scheduleArguments])
        #expect(store.draft == draft)
        #expect(store.savedPolicyNeedsReconciliation == (outcome == .unreadable))
        #expect(store.requiresRestart == (outcome != .unchanged))
        #expect(store.hasUnsavedChanges == !(idleOnly && outcome == .committed))
        guard case .failed(let message) = store.saveState else {
            Issue.record("Expected a failed invoked write")
            return
        }
        #expect(!message.contains("write succeeded"))
        if outcome == .committed {
            #expect(store.savedPolicy?.mode == (idleOnly ? .wheneverRunning : .scheduled))
            #expect(store.savedPolicy?.idleUnloadMinutes == (idleOnly ? 120 : 60))
        }
        if outcome == .unreadable {
            store.discardDraftChanges()
            store.dismissSaveResult()
            #expect(store.draft == draft)
            #expect(store.hasUnsavedChanges)
            #expect(store.requiresRestart)
        }
    }

    @Test("an unverified first write forces a complete retry even when draft matches cached values")
    func retryAfterUnverifiedFirstWrite() async throws {
        let cli = ScriptedCLI(
            reads: [.success(Self.initial), .failure(.invalidOutput("readback failed"))],
            writes: [.failure(Self.writeError), .success(()), .success(())])
        let store = try await editedStore(cli: cli)
        let original = try #require(store.savedPolicy)
        await store.saveAndRestartPreview()
        store.replaceDraft(original)
        #expect(store.hasUnsavedChanges)
        #expect(store.canSaveAndRestart)
        await store.saveAndRestartPreview()
        #expect(await cli.appliedArguments == [
            Self.scheduleArguments,
            ["config", "set", "schedule", "always"],
            ["config", "set", "schedule", "idle-timeout-minutes", "60"],
        ])
        #expect(!store.savedPolicyNeedsReconciliation)
        #expect(!store.hasUnsavedChanges)
        #expect(store.requiresRestart)
    }

}
