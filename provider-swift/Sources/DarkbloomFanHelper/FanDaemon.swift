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

    private let logger = Logger(subsystem: "io.darkbloom.fan", category: "daemon")
    private let configuration: FanServiceConfiguration
    private let paths: FanServicePaths
    private let backend: any SMCBackend
    private let inventory: FanInventory
    private let reader: FanHardwareReader
    private let controller: TransactionalFanController
    private let uptime: Uptime
    private let journalOwner: (uid: uid_t, gid: gid_t)?
    private let requireRootJournalOwnership: Bool
    private let recordFanOwnership: @Sendable () throws -> Void
    private let recordFtstOwnership: @Sendable () throws -> Void

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
        requireRootJournalOwnership: Bool = true
    ) {
        self.configuration = configuration
        self.paths = paths
        self.backend = backend
        self.inventory = inventory
        self.reader = reader
        self.controller = controller
        self.uptime = uptime
        self.journalOwner = journalOwner
        self.requireRootJournalOwnership = requireRootJournalOwnership
        let journalURL = paths.sessionJournal
        let fanIndices = inventory.fans.map(\.index)
        let recordOwnership: @Sendable (Bool) throws -> Void = { ownsFtst in
            try FanDurableFile.writeJSON(
                FanSessionJournal(
                    fanIndices: fanIndices,
                    ownsFtst: ownsFtst
                ),
                to: journalURL,
                permissions: 0o600,
                owner: journalOwner
            )
        }
        self.recordFanOwnership = {
            try recordOwnership(false)
        }
        self.recordFtstOwnership = {
            try recordOwnership(true)
        }
        self.policy = FanPolicyStateMachine(configuration: configuration.policy)
        self.mode = configuration.enabled ? .waitingForProvider : .disabled
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
            chip: inventory.chipFamily.rawValue,
            gpuSensorKeys: inventory.gpuTemperatureKeys.map(\.rawValue),
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
            lastError: lastError
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
            mode = await restoreAutomatic(reason: "fan control disabled")
                ? .disabled : .error
            return
        }
        guard !inventory.fans.isEmpty, !inventory.gpuTemperatureKeys.isEmpty else {
            mode = await restoreAutomatic(
                reason: "fan hardware or GPU sensors unavailable"
            ) ? .unsupported : .error
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
            lastError = nil
        } catch {
            lastError = String(describing: error)
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
                let session = try await controller.engage(
                    speedPercent: speedPercent,
                    beforeFanWrite: recordFanOwnership,
                    beforeFtstWrite: recordFtstOwnership
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
                    beforeFtstWrite: recordFtstOwnership
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
                try await controller.restoreAutomatic()
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

    private func describe(_ mode: FanMode) -> String {
        switch mode {
        case .automatic: return "auto"
        case .manual: return "manual"
        case .system: return "system"
        case .unknown(let value): return "unknown(\(value))"
        }
    }
}
