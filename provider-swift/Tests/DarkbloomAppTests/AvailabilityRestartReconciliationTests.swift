import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("Availability restart evidence")
@MainActor
struct AvailabilityRestartReconciliationTests {
    private func savedStore(
        cli: AvailabilityRestartCLI,
        environment: AvailabilityRestartEnvironment
    ) async throws -> AvailabilityStore {
        let store = AvailabilityStore(
            cli: cli, stateFileURL: environment.stateURL,
            now: { environment.now },
            readProcessIdentity: { environment.identity(for: $0) })
        await store.refresh()
        store.setMode(.scheduled)
        store.addWindow(AvailabilityWindow(
            id: "retained-draft", days: [.monday],
            start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0)),
            end: try #require(AvailabilityTimeOfDay(hour: 10, minute: 0))))
        store.setIdleUnloadMinutes(120)
        await store.saveAndRestartPreview()
        return store
    }

    @Test("verified new generation clears partial warning and retains draft", arguments: [false, true])
    func clearsAfterVerifiedRestart(idleCommittedBeforeFailure: Bool) async throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        let cli = AvailabilityRestartCLI(idleCommittedBeforeFailure: idleCommittedBeforeFailure)
        let store = try await savedStore(cli: cli, environment: environment)
        let draft = store.draft
        #expect(store.requiresRestart)
        #expect(!store.savedPolicyNeedsReconciliation)
        store.dismissSaveResult()
        if idleCommittedBeforeFailure { await store.saveAndRestartPreview() }
        #expect(store.requiresRestart)
        #expect(await cli.writeCount == 2)

        environment.advanceClock()
        try environment.publish(environment.newGeneration())
        await store.refresh()
        #expect(!store.requiresRestart)
        #expect(!store.partialSaveRequiresRestart)
        #expect(store.saveState == .idle)
        #expect(store.draft == draft)
        #expect(store.hasUnsavedChanges == !idleCommittedBeforeFailure)
        #expect(await cli.writeCount == 2)
        // A later ordinary refresh must not erase the preserved unsaved edit.
        await store.refresh()
        if !idleCommittedBeforeFailure { #expect(store.draft == draft) }
    }

    enum InvalidEvidence: CaseIterable, Equatable, Sendable {
        case noFile, missingIdentity, deadProcess, reusedPID, oldGeneration
        case oldProcessNewLoop, stale, future, unknownSchema, wrongSchedule
        case missingSchedule, expiredBoundary, unknownMode
    }

    @Test("unverified runtime cannot clear a partial-save warning", arguments: InvalidEvidence.allCases)
    func rejectsInvalidEvidence(_ evidence: InvalidEvidence) async throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        let cli = AvailabilityRestartCLI()
        let store = try await savedStore(cli: cli, environment: environment)
        let draft = store.draft
        environment.advanceClock()
        var state = environment.newGeneration()
        switch evidence {
        case .noFile: break
        case .missingIdentity: state.processIdentity = nil
        case .deadProcess, .reusedPID: break
        case .oldGeneration:
            state.startedAt = AvailabilityRestartEnvironment.savedEpoch - 10
            state.processIdentity = environment.process(startedAt: state.startedAt)
        case .oldProcessNewLoop:
            state.processIdentity = environment.process(startedAt: AvailabilityRestartEnvironment.savedEpoch - 10)
        case .stale: state.writtenAt = environment.now.timeIntervalSince1970 - 91
        case .future: state.writtenAt = environment.now.timeIntervalSince1970 + 1
        case .unknownSchema: state.schema = DaemonState.currentSchema + 1
        case .wrongSchedule: state.schedule?.summary = "Tue 09:00-10:00"
        case .missingSchedule: state.schedule = nil
        case .expiredBoundary: state.schedule?.nextChangeAtEpoch = environment.now.timeIntervalSince1970 - 1
        case .unknownMode: state.schedule?.mode = "unknown"
        }
        if evidence != .noFile { try environment.publish(state) }
        if evidence == .deadProcess { environment.setLiveIdentity(nil) }
        if evidence == .reusedPID {
            environment.setLiveIdentity(environment.process(startedAt: state.startedAt + 1))
        }
        await store.refresh()
        #expect(store.requiresRestart)
        #expect(store.partialSaveRequiresRestart)
        #expect(store.draft == draft)
        #expect(await cli.writeCount == 2)
    }

    @Test("a config change first observed after launch requires a later generation")
    func changedIdlePolicyCannotBorrowEarlierRestart() async throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        let cli = AvailabilityRestartCLI()
        let store = try await savedStore(cli: cli, environment: environment)
        let draft = store.draft
        environment.advanceClock()
        try environment.publish(environment.newGeneration())
        await cli.setIdleTimeout(75)
        await store.refresh()
        #expect(store.savedPolicy?.idleUnloadMinutes == 75)
        #expect(store.requiresRestart)
        await store.refresh()
        #expect(store.requiresRestart)
        #expect(store.draft == draft)

        let laterStart = environment.now.timeIntervalSince1970 + 1
        environment.advanceClock()
        try environment.publish(environment.newGeneration(startedAt: laterStart))
        await store.refresh()
        #expect(!store.requiresRestart)
        #expect(store.draft == draft)
        #expect(store.hasUnsavedChanges)
    }

    @Test("unreadable or incomplete policy breaks restart evidence continuity", arguments: [false, true])
    func failedReadDoesNotClearWarning(missingIdle: Bool) async throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        let cli = AvailabilityRestartCLI()
        let store = try await savedStore(cli: cli, environment: environment)
        let draft = store.draft
        environment.advanceClock()
        try environment.publish(environment.newGeneration())
        if missingIdle { await cli.setIdleTimeout(nil) }
        else { await cli.setReadFailure(true) }
        await store.refresh()
        #expect(store.savedPolicyNeedsReconciliation)
        #expect(store.requiresRestart)
        store.discardDraftChanges()
        #expect(store.draft == draft)

        await cli.setIdleTimeout(60)
        await cli.setReadFailure(false)
        await store.refresh()
        #expect(!store.savedPolicyNeedsReconciliation)
        #expect(store.requiresRestart)
        #expect(store.draft == draft)
    }

    @Test("heartbeat refresh reads config only for a pending verified restart")
    func heartbeatRefreshWaitsForNewGeneration() async throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        let cli = AvailabilityRestartCLI()
        let store = try await savedStore(cli: cli, environment: environment)
        let readsBeforeRestart = await cli.readCount
        let draft = store.draft
        for _ in 0..<3 { await store.refreshAfterObservedRestart() }
        #expect(await cli.readCount == readsBeforeRestart)
        #expect(store.requiresRestart)
        environment.advanceClock()
        try environment.publish(environment.newGeneration())
        await store.refreshAfterObservedRestart()
        #expect(!store.requiresRestart)
        #expect(store.draft == draft)
        #expect(await cli.readCount == readsBeforeRestart + 1)
        await store.refreshAfterObservedRestart()
        #expect(await cli.readCount == readsBeforeRestart + 1)
    }

    @Test("runtime day order does not invalidate an unchanged saved schedule")
    func runtimeDayOrder() throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        environment.advanceClock()
        let policy = AvailabilityPolicy(mode: .scheduled, windows: [AvailabilityWindow(
            id: "test", days: [.monday, .friday],
            start: try #require(AvailabilityTimeOfDay(hour: 9, minute: 0)),
            end: try #require(AvailabilityTimeOfDay(hour: 10, minute: 0)))])
        let checkpoint = AvailabilityRestartCheckpoint(
            policy: policy, verifiedAt: Date(timeIntervalSince1970: AvailabilityRestartEnvironment.savedEpoch))
        var state = environment.newGeneration()
        state.schedule?.summary = "Fri,Mon 09:00-10:00"
        try environment.publish(state)
        #expect(checkpoint.confirmsRestart(state: state, now: environment.now, readIdentity: environment.identity))
        state.schedule?.summary = "Fri,Tue 09:00-10:00"
        #expect(!checkpoint.confirmsRestart(state: state, now: environment.now, readIdentity: environment.identity))
    }

    @Test("successful saves also clear only after a verified runtime refresh")
    func successfulSaveClearsOnVerifiedRefresh() async throws {
        let environment = AvailabilityRestartEnvironment()
        defer { environment.removeState() }
        let cli = AvailabilityRestartCLI(failIdle: false)
        let store = try await savedStore(cli: cli, environment: environment)
        #expect(store.requiresRestart)
        #expect(!store.partialSaveRequiresRestart)
        await store.refresh()
        #expect(store.requiresRestart)
        environment.advanceClock()
        try environment.publish(environment.newGeneration())
        await store.refresh()
        #expect(!store.requiresRestart)
        #expect(store.saveState == .idle)
        #expect(!store.hasUnsavedChanges)
    }
}

/// Config I/O is entirely in memory; only the explicitly supplied synthetic
/// daemon file is read by the store. No real CLI or process lookup is used.
private actor AvailabilityRestartCLI: AvailabilityCLIRunning {
    private var payload = AvailabilityCLISchedule(enabled: false, windows: [], idleTimeoutMinutes: 60)
    private var failIdle: Bool
    private let idleCommittedBeforeFailure: Bool
    private var readFailure = false
    private(set) var writeCount = 0
    private(set) var readCount = 0

    init(failIdle: Bool = true, idleCommittedBeforeFailure: Bool = false) {
        self.failIdle = failIdle
        self.idleCommittedBeforeFailure = idleCommittedBeforeFailure
    }

    func fetchSchedule() throws -> AvailabilityCLISchedule {
        readCount += 1
        if readFailure { throw AvailabilityCLIError.invalidOutput("readback failed") }
        return payload
    }

    func apply(arguments: [String]) throws {
        writeCount += 1
        if arguments.contains("idle-timeout-minutes") {
            if !failIdle || idleCommittedBeforeFailure { payload.idleTimeoutMinutes = 120 }
            if failIdle {
                failIdle = false
                throw AvailabilityCLIError.timedOut(command: "config set schedule idle-timeout-minutes 120")
            }
        } else {
            payload.enabled = true
            payload.windows = [.init(days: ["mon"], start: "09:00", end: "10:00")]
        }
    }

    func setIdleTimeout(_ minutes: Int?) { payload.idleTimeoutMinutes = minutes }
    func setReadFailure(_ failure: Bool) { readFailure = failure }
}

private final class AvailabilityRestartEnvironment: @unchecked Sendable {
    static let savedEpoch = 1_800_000_000.0
    let stateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("availability-restart-\(UUID().uuidString).json")
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: AvailabilityRestartEnvironment.savedEpoch)
    private var liveIdentity: ProcessIdentity?

    var now: Date { lock.withLock { date } }
    func advanceClock() { lock.withLock { date.addTimeInterval(200) } }
    func setLiveIdentity(_ identity: ProcessIdentity?) { lock.withLock { liveIdentity = identity } }
    func identity(for pid: Int32) -> ProcessIdentity? {
        lock.withLock { liveIdentity?.pid == pid ? liveIdentity : nil }
    }

    func process(startedAt: Double) -> ProcessIdentity {
        ProcessIdentity(pid: 7201, startTimeMicros: UInt64(startedAt * 1_000_000))
    }

    func newGeneration(startedAt: Double = AvailabilityRestartEnvironment.savedEpoch + 1) -> DaemonState {
        DaemonState(pid: 7201, processIdentity: process(startedAt: startedAt), version: "test",
                    writtenAt: now.timeIntervalSince1970, startedAt: startedAt,
                    schedule: .init(mode: "scheduled-active", summary: "Mon 09:00-10:00",
                                    nextChangeAtEpoch: now.timeIntervalSince1970 + 3_600))
    }

    func publish(_ state: DaemonState) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        setLiveIdentity(state.processIdentity)
    }

    func removeState() { try? FileManager.default.removeItem(at: stateURL) }
}
