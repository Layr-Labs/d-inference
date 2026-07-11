import Foundation

protocol FanHardwareDriving: AnyObject {
    var isControlling: Bool { get }
    var targetRPMs: [Int] { get }

    func sample(inferenceActive: Bool) -> FanCoolingSample
    func engage(
        speedPercent: Double,
        shouldStop: () -> Bool
    ) throws -> [Int]
    func maintain(shouldStop: () -> Bool) throws
    func restoreAutomatic() throws
    func forceAutomatic() throws
}

final class SMCFanHardwareDriver: FanHardwareDriving {
    private let smc: AppleSMC
    private var hardware: FanHardware
    private var actuator: FanActuator

    init() throws {
        let smc = try AppleSMC()
        let hardware = try FanHardwareDiscovery.discover(
            on: smc,
            includeTemperatures: true
        )
        self.smc = smc
        self.hardware = hardware
        actuator = try FanActuator(smc: smc, hardware: hardware)
    }

    static func recoverStaleControl() throws {
        let smc = try AppleSMC()
        let hardware = try FanHardwareDiscovery.discoverForReset(on: smc)
        try FanActuator.forceAutomatic(smc: smc, hardware: hardware)
    }

    var isControlling: Bool {
        actuator.isControlling
    }

    var targetRPMs: [Int] {
        actuator.targetRPMs
    }

    func sample(inferenceActive: Bool) -> FanCoolingSample {
        let reading = FanHardwareDiscovery.hottestTemperature(
            on: smc,
            sensors: hardware.temperatureSensors
        )
        return FanCoolingSample(
            inferenceActive: inferenceActive,
            hottestTemperatureCelsius: reading?.celsius,
            hottestSensor: reading?.sensor,
            thermalPressure: Self.currentThermalPressure()
        )
    }

    func engage(
        speedPercent: Double,
        shouldStop: () -> Bool
    ) throws -> [Int] {
        try actuator.engage(
            speedPercent: speedPercent,
            shouldStop: shouldStop
        )
    }

    func maintain(shouldStop: () -> Bool) throws {
        try actuator.maintain(shouldStop: shouldStop)
    }

    func restoreAutomatic() throws {
        try actuator.restoreAutomatic()
    }

    func forceAutomatic() throws {
        let recoveryHardware = try FanHardwareDiscovery.discoverForReset(
            on: smc
        )
        try FanActuator.forceAutomatic(
            smc: smc,
            hardware: recoveryHardware
        )
        hardware = try FanHardwareDiscovery.discover(
            on: smc,
            includeTemperatures: true
        )
        actuator = try FanActuator(smc: smc, hardware: hardware)
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
