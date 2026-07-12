import DarkbloomFanCore
import DarkbloomFanService
import Foundation
import OSLog

#if canImport(Darwin)
import Darwin
#endif

private let logger = Logger(subsystem: "io.darkbloom.fan", category: "main")

guard geteuid() == 0 else {
    logger.fault("fan helper must run as root")
    exit(77)
}

guard FanCodeRequirements.ownIdentityIsProduction else {
    logger.fault("fan helper does not have the expected Darkbloom Developer ID identity")
    exit(78)
}

let paths = FanServicePaths.production
do {
    let backend = try AppleSMCBackend()
    let reader = FanHardwareReader(backend: backend)
    let recoveryInventory = try reader.discoverForRecovery()

    try FanOwnershipRecovery.reconcile(
        backend: backend,
        inventory: recoveryInventory,
        journalURL: paths.sessionJournal
    )
    let inventory = try reader.discover()

    let configuration: FanServiceConfiguration
    do {
        let loaded = try FanDurableFile.readJSON(
            FanServiceConfiguration.self,
            from: paths.configuration
        )
        guard loaded.configuredUID != 0,
              try FanUserIdentity.generatedUID(for: loaded.configuredUID)
                == loaded.configuredUserUUID
        else {
            throw FanDurableFileError.unsafeFile("configured provider UID is invalid")
        }
        configuration = loaded
    } catch {
        // Recovery is deliberately complete before policy parsing. A corrupt
        // config can disable control, but must never strand a prior manual mode.
        logger.fault("cannot load root fan policy; running disabled: \(String(describing: error), privacy: .public)")
        configuration = FanServiceConfiguration(
            enabled: false,
            configuredUID: UInt32.max,
            configuredUserUUID: "00000000-0000-0000-0000-000000000000",
            policy: .defaults
        )
    }

    let controller = TransactionalFanController(
        backend: backend,
        inventory: inventory
    )
    let daemon = FanDaemon(
        configuration: configuration,
        paths: paths,
        backend: backend,
        inventory: inventory,
        reader: reader,
        controller: controller
    )
    let xpcService = FanXPCService(
        daemon: daemon,
        configuredUID: configuration.configuredUID,
        configuredUserUUID: configuration.configuredUserUUID
    )
    let powerMonitor = try FanPowerMonitor(daemon: daemon)

    Task { await daemon.start() }
    xpcService.start()

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let stop: @Sendable () -> Void = {
        Task {
            await daemon.shutdown()
            exit(0)
        }
    }
    termSource.setEventHandler(handler: stop)
    interruptSource.setEventHandler(handler: stop)
    termSource.resume()
    interruptSource.resume()

    logger.notice("fan helper started")
    withExtendedLifetime((xpcService, powerMonitor, termSource, interruptSource)) {
        RunLoop.main.run()
    }
} catch {
    logger.fault("fan helper startup failed: \(String(describing: error), privacy: .public)")
    exit(1)
}
