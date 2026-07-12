import DarkbloomFanCore
import DarkbloomFanProtocol
import DarkbloomFanService
import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum FanServiceManagerError: Error, CustomStringConvertible {
    case rootRequired
    case sudoUserRequired
    case invalidInvokingUID(String)
    case helperNotBundled([String])
    case unsafeFile(String)
    case signatureFailed(String)
    case launchctlFailed(String)
    case unsupported(String)
    case restoreFailed(String)

    var description: String {
        switch self {
        case .rootRequired:
            return "this operation requires administrator privileges; rerun it with sudo"
        case .sudoUserRequired:
            return "run this command through sudo from the provider account (SUDO_UID is required)"
        case .invalidInvokingUID(let value):
            return "invalid invoking user ID: \(value)"
        case .helperNotBundled(let paths):
            return "signed fan helper was not found; reinstall Darkbloom (searched: \(paths.joined(separator: ", ")))"
        case .unsafeFile(let detail): return detail
        case .signatureFailed(let detail): return "fan helper signature verification failed: \(detail)"
        case .launchctlFailed(let detail): return "fan launchd operation failed: \(detail)"
        case .unsupported(let detail): return "fan control is unavailable: \(detail)"
        case .restoreFailed(let detail): return "could not verify automatic fan control: \(detail)"
        }
    }
}

struct FanServiceManager {
    static let label = FanIPC.machServiceName
    static let target = "system/\(label)"

    let paths: FanServicePaths
    let environment: [String: String]

    init(
        paths: FanServicePaths = .production,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.paths = paths
        self.environment = environment
    }

    func enable(policy: FanPolicyConfiguration) throws -> FanServiceStatus {
        try requireRoot()
        let configuredUID = try invokingUID()
        let configuredUserUUID = try FanUserIdentity.generatedUID(for: configuredUID)
        let recoveryHardware = try hardwareForRecovery()

        let source = try bundledHelperURL()
        try verifyRegularExecutable(source)
        try verifyHelperSignature(source)

        // An existing helper may own the fans. Restore first, then boot it out
        // before replacing its executable or policy.
        _ = try? FanHelperClient().restoreAutomatic()
        try bootoutIfLoaded()
        try recoverJournalIfPresent(hardware: recoveryHardware)
        let hardware = try hardwareForControl()
        try preflightAutomaticHardware(hardware)

        do {
            try installHelper(from: source)
            try ensureRootDirectory(paths.configuration.deletingLastPathComponent())
            try FanDurableFile.writeJSON(
                FanServiceConfiguration(
                    enabled: true,
                    configuredUID: configuredUID,
                    configuredUserUUID: configuredUserUUID,
                    policy: policy
                ),
                to: paths.configuration,
                permissions: 0o600
            )
            try writeLaunchDaemonPlist()
            try setLabelEnabled(true)
            try bootstrap()
            try kickstart()

            for _ in 0..<30 {
                if let status = try? FanHelperClient().status() {
                    guard status.enabled,
                          status.configuredUID == configuredUID,
                          status.protocolVersion == FanIPC.protocolVersion
                    else {
                        throw FanServiceManagerError.launchctlFailed(
                            "helper status does not match the installed policy"
                        )
                    }
                    return status
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw FanServiceManagerError.launchctlFailed(
                "helper started but did not answer status"
            )
        } catch {
            let enableError = error
            _ = try? FanHelperClient().restoreAutomatic()
            do {
                try bootoutIfLoaded()
            } catch {
                // Do not disable KeepAlive when the process could still own the
                // fans. Its lease expiry and policy loop remain recovery paths.
                throw FanServiceManagerError.restoreFailed(
                    "enable failed (\(enableError)); helper could not be stopped safely (\(error))"
                )
            }

            do {
                try recoverJournalIfPresent(hardware: hardware)
            } catch let recoveryError {
                // Auto is not verified. Keep/restart the helper so startup
                // reconciliation continues retrying the durable journal.
                var restartError: Error?
                var restarted = false
                do {
                    try setLabelEnabled(true)
                    try bootstrap()
                    try kickstart()
                    restarted = isLoaded()
                    if !restarted {
                        throw FanServiceManagerError.launchctlFailed(
                            "recovery helper did not remain loaded"
                        )
                    }
                } catch {
                    restartError = error
                }
                if restarted {
                    throw FanServiceManagerError.restoreFailed(
                        "enable failed (\(enableError)); cleanup failed (\(recoveryError)); helper was restarted to keep retrying Auto"
                    )
                }

                var directRecoverySucceeded = false
                var lastRecoveryError: Error = recoveryError
                for _ in 0..<20 {
                    Thread.sleep(forTimeInterval: 0.1)
                    do {
                        try recoverJournalIfPresent(hardware: hardware)
                        directRecoverySucceeded = true
                        break
                    } catch {
                        lastRecoveryError = error
                    }
                }
                guard directRecoverySucceeded else {
                    throw FanServiceManagerError.restoreFailed(
                        "enable failed (\(enableError)); helper restart failed (\(restartError.map { String(describing: $0) } ?? "unknown")); direct Auto retries failed (\(lastRecoveryError))"
                    )
                }
            }

            var cleanupFailure: Error?
            do {
                try FanDurableFile.writeJSON(
                    FanServiceConfiguration(
                        enabled: false,
                        configuredUID: configuredUID,
                        configuredUserUUID: configuredUserUUID,
                        policy: policy
                    ),
                    to: paths.configuration,
                    permissions: 0o600
                )
            } catch {
                cleanupFailure = error
            }
            do {
                try setLabelEnabled(false)
            } catch {
                cleanupFailure = cleanupFailure ?? error
            }
            if let cleanupFailure {
                throw FanServiceManagerError.restoreFailed(
                    "enable failed (\(enableError)); disabling failed (\(cleanupFailure))"
                )
            }
            throw enableError
        }
    }

    func configure(policy: FanPolicyConfiguration) throws {
        try requireRoot()
        let current = try FanDurableFile.readJSON(
            FanServiceConfiguration.self,
            from: paths.configuration
        )
        try FanDurableFile.writeJSON(
            FanServiceConfiguration(
                enabled: current.enabled,
                configuredUID: current.configuredUID,
                configuredUserUUID: current.configuredUserUUID,
                policy: policy
            ),
            to: paths.configuration,
            permissions: 0o600
        )
        if isLoaded() {
            let result = FanProcessRunner.run(
                "/bin/launchctl",
                arguments: ["kickstart", "-k", Self.target]
            )
            guard result.succeeded else {
                throw FanServiceManagerError.launchctlFailed(result.output)
            }
        }
    }

    func disable() throws {
        try requireRoot()
        let current: FanServiceConfiguration
        if let loaded = try? FanDurableFile.readJSON(
            FanServiceConfiguration.self,
            from: paths.configuration
        ) {
            current = loaded
        } else {
            let fallbackUID = try invokingUID()
            current = FanServiceConfiguration(
                enabled: false,
                configuredUID: fallbackUID,
                configuredUserUUID: try FanUserIdentity.generatedUID(
                    for: fallbackUID
                ),
                policy: .defaults
            )
        }
        try ensureRootDirectory(paths.configuration.deletingLastPathComponent())
        try FanDurableFile.writeJSON(
            FanServiceConfiguration(
                enabled: false,
                configuredUID: current.configuredUID,
                configuredUserUUID: current.configuredUserUUID,
                policy: current.policy
            ),
            to: paths.configuration,
            permissions: 0o600
        )

        // XPC is the fast path, not the only recovery authority. Always boot
        // out and reconcile the durable journal even if the helper is wedged.
        if isLoaded() { _ = try? FanHelperClient().restoreAutomatic() }
        do {
            try bootoutWithRetries()
        } catch let bootoutError {
            // Force a restart into the persisted disabled policy. The new
            // process repairs the journal before it can accept XPC leases.
            do {
                try restartDisabledHelperForRecovery()
            } catch {
                throw FanServiceManagerError.restoreFailed(
                    "could not stop helper (\(bootoutError)) or restart it disabled (\(error))"
                )
            }
            guard waitForJournalClear() else {
                throw FanServiceManagerError.restoreFailed(
                    "helper remains loaded and disabled while retrying automatic restoration"
                )
            }
            try bootoutWithRetries()
            try setLabelEnabled(false)
            return
        }

        do {
            try recoverJournalIfPresent(hardware: try hardwareForRecovery())
        } catch let recoveryError {
            do {
                try restartDisabledHelperForRecovery()
            } catch {
                throw FanServiceManagerError.restoreFailed(
                    "direct Auto failed (\(recoveryError)); recovery helper restart also failed (\(error))"
                )
            }
            guard waitForJournalClear() else {
                throw FanServiceManagerError.restoreFailed(
                    "helper remains loaded and disabled while retrying automatic restoration"
                )
            }
            try bootoutWithRetries()
        }
        try setLabelEnabled(false)
    }

    func uninstall() throws {
        try disable()
        guard !FileManager.default.fileExists(atPath: paths.sessionJournal.path) else {
            throw FanServiceManagerError.restoreFailed(
                "ownership journal remains after restore; refusing to remove recovery material"
            )
        }
        try FanDurableFile.remove(paths.launchDaemonPlist)
        try FanDurableFile.remove(paths.helper)
        try FanDurableFile.remove(paths.configuration)
    }

    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: paths.helper.path)
            && FileManager.default.fileExists(atPath: paths.launchDaemonPlist.path)
    }

    func configuration() throws -> FanServiceConfiguration {
        try FanDurableFile.readJSON(
            FanServiceConfiguration.self,
            from: paths.configuration
        )
    }

    func isLoaded() -> Bool {
        FanProcessRunner.run(
            "/bin/launchctl",
            arguments: ["print", Self.target],
            timeout: 5
        ).succeeded
    }

    private func requireRoot() throws {
        guard geteuid() == 0 else { throw FanServiceManagerError.rootRequired }
    }

    private func invokingUID() throws -> UInt32 {
        guard let raw = environment["SUDO_UID"], !raw.isEmpty else {
            throw FanServiceManagerError.sudoUserRequired
        }
        guard let uid = UInt32(raw), uid != 0, getpwuid(uid_t(uid)) != nil else {
            throw FanServiceManagerError.invalidInvokingUID(raw)
        }
        return uid
    }

    private typealias Hardware = (
        backend: AppleSMCBackend,
        reader: FanHardwareReader,
        inventory: FanInventory
    )

    private func hardwareForControl() throws -> Hardware {
        let backend = try AppleSMCBackend()
        let reader = FanHardwareReader(backend: backend)
        let hardware: Hardware = (backend, reader, try reader.discover())
        guard !hardware.inventory.fans.isEmpty else {
            throw FanServiceManagerError.unsupported("this Mac reports no fans")
        }
        guard !hardware.inventory.gpuTemperatureKeys.isEmpty else {
            throw FanServiceManagerError.unsupported(
                "no validated GPU temperature sensor was found for \(hardware.inventory.chipFamily.rawValue)"
            )
        }
        return hardware
    }

    private func hardwareForRecovery() throws -> Hardware {
        let backend = try AppleSMCBackend()
        let reader = FanHardwareReader(backend: backend)
        return (backend, reader, try reader.discoverForRecovery())
    }

    private func preflightAutomaticHardware(_ hardware: Hardware) throws {
        let readings = try hardware.reader.fanReadings(in: hardware.inventory)
        let foreign = readings.filter { $0.mode == .manual }.map { $0.capability.index }
        guard foreign.isEmpty else {
            throw FanServiceManagerError.unsupported(
                "another application manually controls fans \(foreign)"
            )
        }
        if let ftst = hardware.inventory.ftstKey {
            let value = try hardware.backend.read(ftst).uint8()
            guard value == 0 else {
                throw FanServiceManagerError.unsupported(
                    "another application holds the Ftst fan-control gate"
                )
            }
        }
    }

    private func recoverJournalIfPresent(hardware: Hardware) throws {
        do {
            try FanOwnershipRecovery.reconcile(
                backend: hardware.backend,
                inventory: hardware.inventory,
                journalURL: paths.sessionJournal
            )
        } catch {
            throw FanServiceManagerError.restoreFailed(String(describing: error))
        }
    }

}
