import Foundation
import Darwin

public final class FanCoolingRunner {
    private let configuration: FanCoolingConfiguration
    private let stateFile: URL
    private let processLock: FanControlProcessLock
    private let smc: AppleSMC
    private let hardware: FanHardware
    private let actuator: FanActuator
    private let activity: FanProviderActivityReader

    public init(
        configuration: FanCoolingConfiguration,
        stateFile: URL
    ) throws {
        try Self.validateRuntime()

        let acquiredLock = try FanControlProcessLock.acquire()
        let smcClient = try AppleSMC()
        let detectedHardware = try FanHardwareDiscovery.discover(
            on: smcClient,
            includeTemperatures: true
        )
        let fanActuator = try FanActuator(
            smc: smcClient,
            hardware: detectedHardware
        )

        self.configuration = configuration
        self.stateFile = stateFile
        processLock = acquiredLock
        smc = smcClient
        hardware = detectedHardware
        actuator = fanActuator
        activity = FanProviderActivityReader(stateFile: stateFile)
    }

    public func run(
        shouldStop: () -> Bool,
        wait: (TimeInterval) -> Bool,
        onEvent: (FanCoolingEvent) -> Void
    ) throws {
        onEvent(.ready(summary))

        do {
            try runLoop(
                shouldStop: shouldStop,
                wait: wait,
                onEvent: onEvent
            )
        } catch let operationError {
            do {
                try actuator.restoreAutomatic()
                onEvent(.restored)
            } catch let restoreError {
                throw FanControlError.operationAndRestoreFailed(
                    operation: operationError.localizedDescription,
                    restore: restoreError.localizedDescription
                )
            }
            if case FanControlError.interrupted = operationError,
               shouldStop() {
                return
            }
            throw operationError
        }

        try actuator.restoreAutomatic()
        onEvent(.restored)
    }

    public static func resetToAutomatic() throws {
        try validateRuntime()
        let lock = try FanControlProcessLock.acquire()
        try withExtendedLifetime(lock) {
            let smc = try AppleSMC()
            let hardware = try FanHardwareDiscovery.discoverForReset(on: smc)
            try FanActuator.forceAutomatic(smc: smc, hardware: hardware)
        }
    }

    private var summary: FanCoolingSummary {
        FanCoolingSummary(
            stateFile: stateFile,
            temperatureSensorCount: hardware.temperatureSensors.count,
            fans: zip(
                hardware.fans,
                actuator.plannedRPMs(
                    speedPercent: configuration.speedPercent
                )
            ).map { fan, target in
                FanCoolingFanSummary(
                    index: fan.index,
                    minimumRPM: Int(fan.minimumRPM.rounded()),
                    maximumRPM: Int(fan.maximumRPM.rounded()),
                    plannedRPM: target
                )
            }
        )
    }

    private func runLoop(
        shouldStop: () -> Bool,
        wait: (TimeInterval) -> Bool,
        onEvent: (FanCoolingEvent) -> Void
    ) throws {
        var temperatureUnavailable = false

        while !shouldStop() {
            let reading = FanHardwareDiscovery.hottestTemperature(
                on: smc,
                sensors: hardware.temperatureSensors
            )
            let sample = FanCoolingSample(
                inferenceActive: activity.inferenceActive(),
                hottestTemperatureCelsius: reading?.celsius,
                hottestSensor: reading?.sensor,
                thermalPressure: Self.currentThermalPressure()
            )

            if reading == nil, !temperatureUnavailable {
                onEvent(.warning(
                    "temperature readings are unavailable; leaving fans under macOS control"
                ))
                temperatureUnavailable = true
            } else if reading != nil {
                temperatureUnavailable = false
            }

            switch FanCoolingPolicy.decide(
                configuration: configuration,
                isBoosted: actuator.isControlling,
                sample: sample
            ) {
            case .engage:
                let targets = try actuator.engage(
                    speedPercent: configuration.speedPercent,
                    shouldStop: shouldStop
                )
                onEvent(.boosted(sample: sample, targetRPMs: targets))
            case .maintain:
                try actuator.maintain(shouldStop: shouldStop)
            case .release(let reason):
                try actuator.restoreAutomatic()
                onEvent(.released(reason: reason, sample: sample))
            }

            if wait(configuration.pollIntervalSeconds) {
                break
            }
        }
    }

    private static func validateRuntime() throws {
        #if arch(arm64)
        guard geteuid() == 0 else {
            throw FanControlError.rootRequired
        }
        #else
        throw FanControlError.unsupportedArchitecture
        #endif
    }

    private static func currentThermalPressure() -> FanThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }
}
