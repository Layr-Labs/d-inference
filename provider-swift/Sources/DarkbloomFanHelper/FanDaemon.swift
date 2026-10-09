import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation
import OSLog

#if canImport(Darwin)
import Darwin
#endif

private enum FanDaemonError: Error {
    case automaticRestoreFailed
}

actor FanDaemon {
    typealias Uptime = @Sendable () -> TimeInterval
    private static let maintenanceIntervalSeconds: TimeInterval = 5
    private static let discoveryRetryIntervalSeconds: TimeInterval = 30

    private let logger = Logger(subsystem: "io.darkbloom.fan", category: "daemon")
    private let configuration: FanServiceConfiguration
    private let paths: FanServicePaths
    private let backend: any SMCBackend
    private var inventory: FanInventory
    private let reader: FanHardwareReader
    private var controller: TransactionalFanController
    private let uptime: Uptime
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let journalOwner: (uid: uid_t, gid: gid_t)?
    private let requireRootJournalOwnership: Bool
    private let recordOwnership: @Sendable (FanControlOwnership) throws -> Void

    private var policy: FanPolicyStateMachine
    private var pollTask: Task<Void, Never>?
    private var providerLease: (sessionID: UUID, expiresAt: TimeInterval)?
    private var powerSuspended = false
    private var administrativelyDisabled = false
    private var shuttingDown = false
    private var lifecycleRevision: UInt64 = 0
    private var discoveryInProgress = false
    private var nextDiscoveryAt: TimeInterval = 0
    private var pendingRestorations = 0
    private var mode: FanServiceMode
    private var gpuTemperatureC: Double?
    private var fanReadings: [FanReading] = []
    private var lastError: String?
    private var lastMaintenanceAt: TimeInterval = 0

    init(
        configuration: FanServiceConfiguration,
        paths: FanServicePaths,
        backend: any SMCBackend,
        inventory: FanInventory,
        reader: FanHardwareReader,
        controller: TransactionalFanController,
        uptime: @escaping Uptime = { ProcessInfo.processInfo.systemUptime },
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        journalOwner: (uid: uid_t, gid: gid_t)? = (0, 0),
        requireRootJournalOwnership: Bool = true
    ) {
        self.configuration = configuration
        self.paths = paths
        self.backend = backend
        self.inventory = inventory
        self.reader = reader
        self.controller = controller
        self.uptime = uptime
        self.thermalState = thermalState
        self.journalOwner = journalOwner
        self.requireRootJournalOwnership = requireRootJournalOwnership
        let journalURL = paths.sessionJournal
        self.recordOwnership = { ownership in
            try FanDurableFile.writeJSON(
                FanSessionJournal(
                    fanIndices: ownership.fanIndices,
                    ownsFtst: ownership.ownsFtst
                ),
                to: journalURL,
                permissions: 0o600,
                owner: journalOwner
            )
        }
        self.policy = FanPolicyStateMachine(configuration: configuration.policy)
        self.mode = configuration.enabled ? .waitingForProvider : .disabled
    }

    func start() {
        guard pollTask == nil, !shuttingDown else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func renewLease(
        sessionID: UUID,
        protocolVersion: Int,
        providerVersion: String
    ) -> FanIPCReply {
        guard effectiveEnabled else {
            return FanIPCReply(ok: false, message: "fan control is disabled")
        }
        guard !powerSuspended else {
            return FanIPCReply(ok: false, message: "system sleep is in progress")
        }
        guard protocolVersion == FanIPC.protocolVersion else {
            return FanIPCReply(
                ok: false,
                message: "helper upgrade required (provider protocol \(protocolVersion), helper protocol \(FanIPC.protocolVersion))"
            )
        }
        guard providerVersion.utf8.count <= 64 else {
            return FanIPCReply(ok: false, message: "provider version is invalid")
        }
        providerLease = (sessionID, uptime() + FanIPC.leaseDurationSeconds)
        return FanIPCReply(ok: true)
    }

    func releaseLease(sessionID: UUID) async -> FanIPCReply {
        if providerLease?.sessionID == sessionID {
            providerLease = nil
            let restored = await restoreAutomatic(reason: "provider lease released")
            return FanIPCReply(
                ok: restored,
                message: restored ? nil : lastError
            )
        }
        return FanIPCReply(ok: true)
    }

    func sessionInvalidated(_ sessionID: UUID) async {
        guard providerLease?.sessionID == sessionID else { return }
        providerLease = nil
        _ = await restoreAutomatic(reason: "provider XPC session ended")
    }

    func emergencyRestore() async -> FanIPCReply {
        administrativelyDisabled = true
        lifecycleRevision &+= 1
        providerLease = nil
        let restored = await restoreAutomatic(reason: "administrator requested Auto")
        return FanIPCReply(ok: restored, message: restored ? nil : lastError)
    }

    func status() -> FanServiceStatus {
        FanServiceStatus(
            enabled: effectiveEnabled,
            configuredUID: configuration.configuredUID,
            providerActive: providerLeaseActive,
            mode: mode,
            chip: inventory.chipFamily.rawValue,
            gpuSensorKeys: inventory.gpuTemperatureKeys.map(\.rawValue),
            gpuTemperatureC: gpuTemperatureC,
            triggerTemperatureC: configuration.policy.triggerCelsius,
            releaseTemperatureC: configuration.policy.releaseCelsius,
            speedPercent: configuration.policy.speedPercent,
            fans: fanReadings.map { FanServiceFanStatus(reading: $0) },
            lastError: lastError
        )
    }

    func shutdown() async {
        shuttingDown = true
        lifecycleRevision &+= 1
        pollTask?.cancel()
        pollTask = nil
        providerLease = nil
        _ = await restoreAutomatic(reason: "fan helper shutting down")
    }

    func prepareForSleep() async {
        powerSuspended = true
        lifecycleRevision &+= 1
        providerLease = nil
        _ = await restoreAutomatic(reason: "system will sleep")
    }

    func didWake() {
        // A fresh provider renewal is required after wake. This prevents a
        // stale pre-sleep lease from reasserting manual mode on resumed hardware.
        powerSuspended = false
        lifecycleRevision &+= 1
        providerLease = nil
        mode = effectiveEnabled ? .waitingForProvider : .disabled
    }

    private var providerLeaseActive: Bool {
        guard let providerLease else { return false }
        return !powerSuspended && uptime() < providerLease.expiresAt
    }

    private var effectiveEnabled: Bool {
        configuration.enabled && !administrativelyDisabled && !shuttingDown
    }

    func tick() async {
        guard !shuttingDown, pendingRestorations == 0 else { return }
        guard effectiveEnabled else {
            mode = await restoreAutomatic(reason: "fan control disabled")
                ? .disabled : .error
            return
        }
        guard !inventory.fans.isEmpty, !inventory.gpuTemperatureKeys.isEmpty else {
            await recoverStartupInventory()
            return
        }
        if (!providerLeaseActive || mode == .error), await hasPossibleOwnership {
            mode = await restoreAutomatic(reason: "retrying automatic restoration")
                ? (providerLeaseActive ? .waitingForTemperature : .waitingForProvider)
                : .error
            return
        }

        do {
            fanReadings = try reader.fanReadings(in: inventory)
            let temperatures = try reader.gpuTemperatures(in: inventory)
            gpuTemperatureC = temperatures.map(\.celsius).max()

            let pressure = thermalState()
            if pressure == .serious || pressure == .critical {
                mode = await restoreAutomatic(
                    reason: "macOS reported serious thermal pressure"
                ) ? .safetyOverride : .error
                return
            }

            let action = policy.evaluate(FanPolicyInput(
                providerLeaseActive: providerLeaseActive,
                gpuTemperaturesCelsius: temperatures.map(\.celsius),
                controlHealthy: true
            ))
            try await apply(action)
            lastError = nil
        } catch {
            lastError = String(describing: error)
            logger.error("fan policy tick failed: \(String(describing: error), privacy: .public)")
            _ = await restoreAutomatic(reason: "fan policy failure")
            mode = .error
        }
    }

    private func recoverStartupInventory() async {
        guard effectiveEnabled, !powerSuspended, !discoveryInProgress else { return }
        discoveryInProgress = true
        defer { discoveryInProgress = false }
        let revision = lifecycleRevision
        mode = .unsupported
        if lastError == nil {
            lastError = "fan hardware or GPU sensors unavailable; discovery will retry"
        }

        let restored = await restoreAutomatic(reason: "fan hardware or GPU sensors unavailable")
        guard recoveryAllowed(revision) else { return }
        guard restored else {
            mode = .error
            return
        }
        mode = .unsupported
        let now = uptime()
        guard now >= nextDiscoveryAt else { return }
        // The first eligible tick tries immediately. Sleep/wake preserves this
        // deadline, and failures never exhaust a process-lifetime retry budget.
        nextDiscoveryAt = now + Self.discoveryRetryIntervalSeconds
        do {
            let discovered = try reader.discover(brandString: inventory.chipFamily.rawValue)
            guard !discovered.fans.isEmpty, !discovered.gpuTemperatureKeys.isEmpty else {
                lastError = "fan hardware or GPU sensors unavailable; discovery will retry"
                return
            }
            let ownsHardware = await hasPossibleOwnership
            guard recoveryAllowed(revision) else { return }
            // An older restoration must finish before replacement: it can still
            // resume on this actor and remove the shared ownership journal.
            guard !ownsHardware, pendingRestorations == 0 else { return }

            // No suspension between the final checks and replacing both owners.
            inventory = discovered
            controller = TransactionalFanController(backend: backend, inventory: discovered)
            providerLease = nil
            _ = policy.reset()
            gpuTemperatureC = nil
            fanReadings = []
            lastMaintenanceAt = 0
            nextDiscoveryAt = 0
            lastError = nil
            mode = .waitingForProvider
        } catch {
            lastError = "fan hardware discovery failed: \(error)"
        }
    }

    private func recoveryAllowed(_ revision: UInt64) -> Bool {
        effectiveEnabled && !powerSuspended && lifecycleRevision == revision
    }

    private func apply(_ action: FanPolicyAction) async throws {
        switch action {
        case .stayAutomatic(let reason):
            mode = serviceMode(for: reason)
        case .engage(let speedPercent, _):
            do {
                let session = try await controller.engage(
                    speedPercent: speedPercent,
                    recordOwnership: recordOwnership
                )
                try persistOwnership(session)
                lastMaintenanceAt = uptime()
                mode = .manual
            } catch {
                if !(await controller.isControlling) {
                    try? FanDurableFile.remove(paths.sessionJournal)
                }
                throw error
            }
        case .maintain:
            if uptime() - lastMaintenanceAt >= Self.maintenanceIntervalSeconds {
                // Refresh the journal with current ownership. The controller
                // widens Ftst ownership only after it observes the gate free,
                // immediately before a possible write.
                if let currentSession = await controller.currentSession() {
                    try persistOwnership(currentSession)
                }
                let session = try await controller.maintain(
                    recordOwnership: recordOwnership
                )
                try persistOwnership(session)
                lastMaintenanceAt = uptime()
            }
            mode = .manual
        case .restoreAutomatic(let reason):
            guard await restoreAutomatic(reason: String(describing: reason)) else {
                throw FanDaemonError.automaticRestoreFailed
            }
            mode = serviceMode(for: reason)
        }
    }

    private func persistOwnership(_ session: FanControlSession) throws {
        try recordOwnership(FanControlOwnership(
            fanIndices: Array(session.targetRPMByFan.keys),
            ownsFtst: session.ownsFtst
        ))
    }

    private func restoreAutomatic(reason: String) async -> Bool {
        pendingRestorations += 1
        defer { pendingRestorations -= 1 }
        guard await hasPossibleOwnership else {
            _ = policy.reset()
            if !providerLeaseActive {
                mode = effectiveEnabled ? .waitingForProvider : .disabled
            }
            return true
        }
        do {
            if await controller.isControlling {
                try await controller.restoreAutomatic(
                    recordOwnership: recordOwnership
                )
            } else {
                try FanOwnershipRecovery.reconcile(
                    backend: backend,
                    inventory: inventory,
                    journalURL: paths.sessionJournal,
                    requireRootOwnership: requireRootJournalOwnership,
                    journalOwner: journalOwner
                )
            }
            try FanDurableFile.remove(paths.sessionJournal)
            _ = policy.reset()
            mode = effectiveEnabled
                ? (providerLeaseActive ? .waitingForTemperature : .waitingForProvider)
                : .disabled
            logger.info("restored automatic fan control: \(reason, privacy: .public)")
            return true
        } catch {
            lastError = "automatic restore failed: \(error)"
            logger.fault("automatic fan restore failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private var hasPossibleOwnership: Bool {
        get async {
            await controller.isControlling
                || FileManager.default.fileExists(atPath: paths.sessionJournal.path)
        }
    }

    private func serviceMode(for reason: FanPolicyReason) -> FanServiceMode {
        switch reason {
        case .providerInactive: return .waitingForProvider
        case .sensorUnavailable, .invalidSensorValue: return .unsupported
        case .controlFailure: return .error
        default: return .waitingForTemperature
        }
    }

}
