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
    case controlAuthorizationChanged
}

actor FanDaemon {
    typealias Uptime = @Sendable () -> TimeInterval
    typealias DiscoverInventory = @Sendable () throws -> FanInventory
    typealias ControllerFactory = @Sendable (FanInventory) -> TransactionalFanController
    private static let maintenanceIntervalSeconds: TimeInterval = 5

    private let logger = Logger(subsystem: "io.darkbloom.fan", category: "daemon")
    private let configuration: FanServiceConfiguration
    private let paths: FanServicePaths
    private let backend: any SMCBackend
    private let reader: FanHardwareReader
    private let uptime: Uptime
    private let journalOwner: (uid: uid_t, gid: gid_t)?
    private let requireRootJournalOwnership: Bool
    private let recordOwnership: @Sendable (FanControlOwnership) throws -> Void
    private let discoverInventory: DiscoverInventory
    private let controllerFactory: ControllerFactory

    private var controller: TransactionalFanController
    private var hardwareRecovery: FanHardwareRecovery

    private var policy: FanPolicyStateMachine
    private var pollTask: Task<Void, Never>?
    private var leaseSessionID: UUID?
    private var leaseExpiresAt: TimeInterval = 0
    private var powerSuspended = false
    private var administrativelyDisabled = false
    private var mode: FanServiceMode
    private var gpuTemperatureC: Double?
    private var fanReadings: [FanReading] = []
    private var lastError: String?
    private var persistedLastError: String?
    private var failureFileMayExist: Bool
    private var lastMaintenanceAt: TimeInterval = 0

    init(
        configuration: FanServiceConfiguration,
        paths: FanServicePaths,
        backend: any SMCBackend,
        inventory: FanInventory,
        reader: FanHardwareReader,
        controller: TransactionalFanController,
        uptime: @escaping Uptime = { ProcessInfo.processInfo.systemUptime },
        journalOwner: (uid: uid_t, gid: gid_t)? = (0, 0),
        requireRootJournalOwnership: Bool = true,
        discoverInventory: DiscoverInventory? = nil,
        controllerFactory: ControllerFactory? = nil,
        baselineSensorKeys: [SMCKey] = [],
        initialLastError: String? = nil,
        initialPersistedLastError: String? = nil,
        initialFailureFileMayExist: Bool = false,
        initialDiscoveryError: String? = nil
    ) {
        self.configuration = configuration
        self.paths = paths
        self.backend = backend
        self.reader = reader
        self.controller = controller
        self.hardwareRecovery = FanHardwareRecovery(
            inventory: inventory,
            initialError: initialDiscoveryError,
            baselineSensorKeys: baselineSensorKeys
        )
        self.uptime = uptime
        self.journalOwner = journalOwner
        self.requireRootJournalOwnership = requireRootJournalOwnership
        self.discoverInventory = discoverInventory ?? {
            try reader.discover()
        }
        self.controllerFactory = controllerFactory ?? { refreshedInventory in
            TransactionalFanController(
                backend: backend,
                inventory: refreshedInventory
            )
        }
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
        self.lastError = initialLastError
        self.persistedLastError = initialPersistedLastError
        self.failureFileMayExist = initialFailureFileMayExist
    }

    func start() {
        guard pollTask == nil else { return }
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
        guard hardwareReady else {
            return FanIPCReply(ok: false, message: hardwareReadinessMessage)
        }
        leaseSessionID = sessionID
        leaseExpiresAt = uptime() + FanIPC.leaseDurationSeconds
        return FanIPCReply(ok: true)
    }

    func releaseLease(sessionID: UUID) async -> FanIPCReply {
        if leaseSessionID == sessionID {
            leaseSessionID = nil
            leaseExpiresAt = 0
            let restored = await restoreAutomatic(reason: "provider lease released")
            return FanIPCReply(
                ok: restored,
                message: restored ? nil : lastError
            )
        }
        return FanIPCReply(ok: true)
    }

    func sessionInvalidated(_ sessionID: UUID) async {
        guard leaseSessionID == sessionID else { return }
        leaseSessionID = nil
        leaseExpiresAt = 0
        _ = await restoreAutomatic(reason: "provider XPC session ended")
    }

    func emergencyRestore() async -> FanIPCReply {
        administrativelyDisabled = true
        leaseSessionID = nil
        leaseExpiresAt = 0
        let restored = await restoreAutomatic(reason: "administrator requested Auto")
        return FanIPCReply(ok: restored, message: restored ? nil : lastError)
    }

    func status() -> FanServiceStatus {
        FanServiceStatus(
            enabled: effectiveEnabled,
            configuredUID: configuration.configuredUID,
            providerActive: providerLeaseActive,
            mode: mode,
            chip: hardwareRecovery.inventory.chipFamily.rawValue,
            gpuSensorKeys: hardwareRecovery.inventory.gpuTemperatureKeys.map(\.rawValue),
            gpuTemperatureC: gpuTemperatureC,
            triggerTemperatureC: configuration.policy.triggerCelsius,
            releaseTemperatureC: configuration.policy.releaseCelsius,
            speedPercent: configuration.policy.speedPercent,
            fans: fanReadings.map { reading in
                FanServiceFanStatus(
                    index: reading.capability.index,
                    actualRPM: reading.actualRPM,
                    targetRPM: reading.targetRPM,
                    minimumRPM: reading.minimumRPM,
                    maximumRPM: reading.maximumRPM,
                    mode: describe(reading.mode)
                )
            },
            lastError: lastError,
            hardwareReady: hardwareReady,
            recoveryPending: hardwareRecovery.recoveryPending
                || hardwareRecovery.baselineNeedsPersistence,
            discoveryError: hardwareRecovery.discoveryError,
            quarantinedSensorKeys: hardwareRecovery.quarantinedSensorKeys
                .map(\.rawValue)
                .sorted()
        )
    }

    func shutdown() async {
        pollTask?.cancel()
        pollTask = nil
        leaseSessionID = nil
        leaseExpiresAt = 0
        _ = await restoreAutomatic(reason: "fan helper shutting down")
    }

    func prepareForSleep() async {
        powerSuspended = true
        leaseSessionID = nil
        leaseExpiresAt = 0
        _ = await restoreAutomatic(reason: "system will sleep")
    }

    func didWake() {
        // A fresh provider renewal is required after wake. This prevents a
        // stale pre-sleep lease from reasserting manual mode on resumed hardware.
        powerSuspended = false
        leaseSessionID = nil
        leaseExpiresAt = 0
        hardwareRecovery.markWake()
        mode = effectiveEnabled ? .waitingForProvider : .disabled
    }

    private var providerLeaseActive: Bool {
        !powerSuspended && leaseSessionID != nil && uptime() < leaseExpiresAt
    }

    private var effectiveEnabled: Bool {
        configuration.enabled && !administrativelyDisabled
    }

    func tick() async {
        guard effectiveEnabled else {
            let restored = await restoreAutomatic(reason: "fan control disabled")
            mode = restored ? .disabled : .error
            if restored {
                clearLastError()
            }
            return
        }
        if (!providerLeaseActive || mode == .error || hardwareRecovery.discoveryRequired),
           await hasPossibleOwnership
        {
            mode = await restoreAutomatic(reason: "retrying automatic restoration")
                ? (providerLeaseActive ? .waitingForTemperature : .waitingForProvider)
                : .error
            return
        }
        if hardwareRecovery.discoveryRequired {
            await refreshHardwareIfDue()
        }
        guard hardwareRecovery.hardwareReady else {
            let message = hardwareReadinessMessage
            setLastError(message)
            mode = .unsupported
            return
        }
        persistSensorBaselineIfNeeded()
        guard hardwareReady else {
            mode = .error
            return
        }

        do {
            fanReadings = try reader.fanReadings(in: hardwareRecovery.inventory)
            let temperatures: [GPUTemperatureReading]
            do {
                temperatures = try reader.gpuTemperatures(
                    in: hardwareRecovery.inventory
                )
            } catch {
                hardwareRecovery.markSensorFailure(error)
                leaseSessionID = nil
                leaseExpiresAt = 0
                throw error
            }
            gpuTemperatureC = temperatures.map(\.celsius).max()

            if ProcessInfo.processInfo.thermalState == .serious
                || ProcessInfo.processInfo.thermalState == .critical
            {
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
            clearLastError()
        } catch {
            let message = String(describing: error)
            setLastError(message)
            logger.error("fan policy tick failed: \(String(describing: error), privacy: .public)")
            _ = await restoreAutomatic(reason: "fan policy failure")
            mode = .error
        }
    }

    private func apply(_ action: FanPolicyAction) async throws {
        switch action {
        case .stayAutomatic(let reason):
            mode = serviceMode(for: reason)
        case .engage(let speedPercent, _):
            do {
                let lease = leaseSessionID
                try await requireControlAuthorization(lease)
                let session = try await controller.engage(
                    speedPercent: speedPercent,
                    recordOwnership: recordOwnership
                )
                try await requireControlAuthorization(lease)
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
                let lease = leaseSessionID
                try await requireControlAuthorization(lease)
                // Refresh the journal with current ownership. The controller
                // widens Ftst ownership only after it observes the gate free,
                // immediately before a possible write.
                if let currentSession = await controller.currentSession() {
                    try persistOwnership(currentSession)
                }
                try await requireControlAuthorization(lease)
                let session = try await controller.maintain(
                    recordOwnership: recordOwnership
                )
                try await requireControlAuthorization(lease)
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
        try FanDurableFile.writeJSON(
            FanSessionJournal(
                fanIndices: session.targetRPMByFan.keys.map { $0 },
                ownsFtst: session.ownsFtst
            ),
            to: paths.sessionJournal,
            permissions: 0o600,
            owner: journalOwner
        )
    }

    private func restoreAutomatic(reason: String) async -> Bool {
        guard await controller.isControlling
            || FileManager.default.fileExists(atPath: paths.sessionJournal.path)
        else {
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
                    inventory: hardwareRecovery.inventory,
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
            setLastError("automatic restore failed: \(error)")
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

    private var hardwareReady: Bool {
        hardwareRecovery.hardwareReady
            && !hardwareRecovery.baselineNeedsPersistence
    }

    private var hardwareReadinessMessage: String {
        if hardwareRecovery.hardwareReady,
           hardwareRecovery.baselineNeedsPersistence
        {
            return "fan sensor baseline is not durable; retrying"
        }
        return hardwareRecovery.readinessMessage
    }

    private func requireControlAuthorization(_ expectedLease: UUID?) async throws {
        guard let expectedLease,
              leaseSessionID == expectedLease,
              providerLeaseActive,
              hardwareReady
        else {
            guard await restoreAutomatic(
                reason: "provider authorization changed during fan control"
            ) else {
                throw FanDaemonError.automaticRestoreFailed
            }
            throw FanDaemonError.controlAuthorizationChanged
        }
    }

    private func refreshHardwareIfDue() async {
        let now = uptime()
        guard hardwareRecovery.beginDiscoveryIfDue(now: now) else {
            return
        }
        guard !(await controller.isControlling),
              !FileManager.default.fileExists(atPath: paths.sessionJournal.path)
        else {
            return
        }

        do {
            let refreshed = try discoverInventory()
            let ready = hardwareRecovery.apply(refreshed)
            controller = controllerFactory(refreshed)
            fanReadings = []
            gpuTemperatureC = nil

            guard ready else { return }
            mode = .waitingForProvider
            logger.notice(
                "fan hardware discovery recovered with \(refreshed.gpuTemperatureKeys.count, privacy: .public) GPU sensors"
            )
        } catch {
            hardwareRecovery.recordDiscoveryFailure(error)
        }
    }

    private func setLastError(_ message: String) {
        lastError = message
        guard persistedLastError != message else { return }
        failureFileMayExist = true
        do {
            try FanDurableFile.writeJSON(
                FanLastFailure(message: message),
                to: paths.lastFailure,
                permissions: 0o600,
                owner: journalOwner
            )
            persistedLastError = message
        } catch {
            persistedLastError = nil
        }
    }

    private func clearLastError() {
        guard lastError != nil || failureFileMayExist else { return }
        lastError = nil
        guard failureFileMayExist else {
            persistedLastError = nil
            return
        }
        do {
            try FanDurableFile.remove(paths.lastFailure)
            persistedLastError = nil
            failureFileMayExist = false
        } catch {
            // Keep the persistence marker so the next healthy tick retries
            // removal without continuing to surface a resolved active error.
        }
    }

    private func persistSensorBaselineIfNeeded() {
        guard hardwareRecovery.baselineNeedsPersistence else { return }
        do {
            try FanDurableFile.writeJSON(
                hardwareRecovery.sensorBaseline,
                to: paths.sensorBaseline,
                permissions: 0o600,
                owner: journalOwner
            )
            hardwareRecovery.markBaselinePersisted()
        } catch {
            setLastError("could not persist fan sensor baseline: \(error)")
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

    private func describe(_ mode: FanMode) -> String {
        switch mode {
        case .automatic: return "auto"
        case .manual: return "manual"
        case .system: return "system"
        case .unknown(let value): return "unknown(\(value))"
        }
    }
}
