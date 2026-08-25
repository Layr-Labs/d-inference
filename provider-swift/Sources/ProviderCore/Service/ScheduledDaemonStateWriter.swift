import Foundation
import ProviderCoreFoundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns `daemon-state.json` while the long-lived provider process is outside
/// its configured availability windows and no serving `ProviderLoop` exists.
///
/// The scheduling supervisor remains a live launchd process during that time.
/// Refreshing a state record with this process's PID/start identity keeps the
/// app on `scheduledOff` and prevents the watchdog from mistaking intentional
/// downtime for a wedged provider.
public actor ScheduledDaemonStateWriter {
    /// Safely below `DaemonState.isStale`'s 90-second default.
    public nonisolated static let refreshIntervalSeconds: TimeInterval = 30

    private let stateFileURL: URL
    private let processID: Int32
    private let processIdentity: ProcessIdentity?
    private let processStartedAt: Double
    private let version: String
    private let providerName: String
    private let operatorAddress: String?
    private var template: DaemonState

    public init(
        loopConfig: ProviderLoopConfig,
        stateFileURL: URL = DaemonStateFile.path()
    ) {
        let capturedAt = Date().timeIntervalSince1970
        let processID = getpid()
        let processIdentity = ProcessIdentity.current()
        let processStartedAt = processIdentity.map {
            Double($0.startTimeMicros) / 1_000_000
        } ?? capturedAt
        let operatorAddress = ProviderAccountStore.load()

        self.stateFileURL = stateFileURL
        self.processID = processID
        self.processIdentity = processIdentity
        self.processStartedAt = processStartedAt
        self.version = ProviderCore.version
        self.providerName = loopConfig.config.provider.name
        self.operatorAddress = operatorAddress
        self.template = DaemonState(
            pid: processID,
            processIdentity: processIdentity,
            version: ProviderCore.version,
            writtenAt: capturedAt,
            startedAt: processStartedAt,
            connectivity: DaemonState.Connectivity(
                reconnectCount: 0,
                lastError: nil
            ),
            identity: DaemonState.Identity(
                providerName: loopConfig.config.provider.name,
                operatorAddress: operatorAddress
            )
        )
    }

    /// Initial launch directly into an off-window: no `ProviderLoop` has
    /// existed yet, so construct the first authoritative supervisor record.
    @discardableResult
    public func persistInitialOffWindow(
        schedule: Schedule,
        at date: Date = Date()
    ) -> DaemonState {
        persistScheduledOff(schedule: schedule, at: date)
    }

    /// Active-window handoff: retain durable session diagnostics/counters from
    /// the loop only when they belong to this exact process, then strip every
    /// serving-only field in the off-window record.
    @discardableResult
    public func persistTransitionFromActive(
        _ activeState: DaemonState,
        schedule: Schedule,
        at date: Date = Date()
    ) -> DaemonState {
        if activeState.pid == processID,
           activeState.processIdentity == processIdentity {
            template = activeState
        }
        return persistScheduledOff(schedule: schedule, at: date)
    }

    /// Periodic off-window liveness refresh.
    @discardableResult
    public func refresh(
        schedule: Schedule,
        at date: Date = Date()
    ) -> DaemonState {
        persistScheduledOff(schedule: schedule, at: date)
    }

    public nonisolated static func refreshDelay(
        untilNextActive wait: TimeInterval
    ) -> TimeInterval {
        max(0.1, min(wait, refreshIntervalSeconds))
    }

    private func persistScheduledOff(
        schedule: Schedule,
        at date: Date
    ) -> DaemonState {
        let timestamp = date.timeIntervalSince1970
        var snapshot = template
        var connectionTruth = CoordinatorConnectionTruth(
            trust: snapshot.trust,
            connectivity: snapshot.connectivity ?? .init(
                reconnectCount: 0,
                lastError: nil
            )
        )
        if connectionTruth.connectivity.status != .disconnected
            || connectionTruth.trust?.status.lowercased() != "offline" {
            connectionTruth.recordDisconnected(
                reason: "Outside configured availability schedule.",
                at: timestamp,
                incrementsReconnectCount: false
            )
        }

        snapshot.schema = DaemonState.currentSchema
        snapshot.pid = processID
        snapshot.processIdentity = processIdentity
        snapshot.version = version
        snapshot.writtenAt = timestamp
        snapshot.startedAt = processStartedAt
        snapshot.trust = connectionTruth.trust
        snapshot.currentModel = nil
        snapshot.warmModels = []
        snapshot.inferenceActive = false
        snapshot.system = nil
        snapshot.capacity = nil
        snapshot.slots = []
        snapshot.connectivity = connectionTruth.connectivity
        snapshot.schedule = DaemonSchedulePostureResolver.resolve(
            schedule: schedule,
            at: date
        )
        snapshot.identity = DaemonState.Identity(
            providerName: providerName,
            operatorAddress: operatorAddress
        )

        template = snapshot
        DaemonStateFile.write(snapshot, to: stateFileURL)
        return snapshot
    }
}
