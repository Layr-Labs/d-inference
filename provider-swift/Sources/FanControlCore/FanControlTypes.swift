import Foundation

public enum FanControlError: Error, LocalizedError, Sendable {
    case rootRequired
    case unsupportedArchitecture
    case appleSMCUnavailable
    case smcABIMismatch(Int)
    case smcOpenFailed(UInt32)
    case smcCallFailed(UInt32)
    case smcRejected(key: String, result: UInt8)
    case smcKeyNotFound(String)
    case smcPermissionDenied
    case invalidSMCData(String)
    case unsupportedSMCType(key: String, type: String)
    case noFans
    case invalidFanCount(Int)
    case fanModeKeyMissing(Int)
    case ambiguousFanModeKeys(Int)
    case fanAlreadyControlled(Int)
    case fanTestModeActive
    case fanControlOwnershipLost
    case noTemperatureSensors
    case writeNotApplied(String)
    case invalidConfiguration(String)
    case leaseBusy
    case leaseNotFound
    case staleLeaseSequence
    case interrupted
    case journalFailed(String)
    case restoreFailed([String])
    case operationAndRestoreFailed(operation: String, restore: String)

    public var errorDescription: String? {
        switch self {
        case .rootRequired:
            return "the fan helper must run as root"
        case .unsupportedArchitecture:
            return "fan control is supported only on Apple Silicon Macs"
        case .appleSMCUnavailable:
            return "AppleSMC is unavailable on this Mac"
        case .smcABIMismatch(let size):
            return "unsupported AppleSMC ABI (parameter size \(size), expected 80)"
        case .smcOpenFailed(let code):
            return "could not open AppleSMC (IOReturn 0x\(String(code, radix: 16)))"
        case .smcCallFailed(let code):
            return "AppleSMC call failed (IOReturn 0x\(String(code, radix: 16)))"
        case .smcRejected(let key, let result):
            return "AppleSMC rejected \(key) (result 0x\(String(result, radix: 16)))"
        case .smcKeyNotFound(let key):
            return "AppleSMC key \(key) was not found"
        case .smcPermissionDenied:
            return "AppleSMC denied the privileged write"
        case .invalidSMCData(let detail):
            return "invalid AppleSMC data: \(detail)"
        case .unsupportedSMCType(let key, let type):
            return "AppleSMC key \(key) uses unsupported type '\(type)'"
        case .noFans:
            return "this Mac reports no controllable fans"
        case .invalidFanCount(let count):
            return "AppleSMC reported an invalid fan count (\(count))"
        case .fanModeKeyMissing(let index):
            return "fan \(index) has no supported manual-mode key"
        case .ambiguousFanModeKeys(let index):
            return "fan \(index) exposes multiple manual-mode keys"
        case .fanAlreadyControlled(let index):
            return "fan \(index) is already controlled by another utility"
        case .fanTestModeActive:
            return "AppleSMC fan test mode is already owned by another utility"
        case .fanControlOwnershipLost:
            return "another utility changed fan control; Darkbloom relinquished its lease"
        case .noTemperatureSensors:
            return "AppleSMC exposed no usable CPU or GPU temperature sensors"
        case .writeNotApplied(let key):
            return "AppleSMC accepted the \(key) write but did not apply it"
        case .invalidConfiguration(let detail):
            return detail
        case .leaseBusy:
            return "another fan-control lease is active"
        case .leaseNotFound:
            return "the fan-control lease is no longer active"
        case .staleLeaseSequence:
            return "the fan-control lease update is stale"
        case .interrupted:
            return "fan control was interrupted"
        case .journalFailed(let detail):
            return "fan recovery journal failed: \(detail)"
        case .restoreFailed(let failures):
            return "could not fully return fan control to macOS: \(failures.joined(separator: "; "))"
        case .operationAndRestoreFailed(let operation, let restore):
            return "\(operation); automatic fan restoration also failed: \(restore)"
        }
    }
}

public struct FanCoolingConfiguration: Sendable, Equatable {
    public static let defaultSpeedPercent = 90.0
    public static let defaultTriggerTemperatureCelsius = 40.0
    public static let defaultPollIntervalSeconds = 2.0
    public static let defaultHysteresisCelsius = 3.0

    public let speedPercent: Double
    public let triggerTemperatureCelsius: Double
    public let pollIntervalSeconds: Double
    public let hysteresisCelsius: Double

    public init(
        speedPercent: Double = Self.defaultSpeedPercent,
        triggerTemperatureCelsius: Double = Self.defaultTriggerTemperatureCelsius,
        pollIntervalSeconds: Double = Self.defaultPollIntervalSeconds,
        hysteresisCelsius: Double = Self.defaultHysteresisCelsius
    ) throws {
        guard speedPercent.isFinite, (90...100).contains(speedPercent) else {
            throw FanControlError.invalidConfiguration(
                "--speed must be between 90 and 100 percent"
            )
        }
        guard triggerTemperatureCelsius.isFinite,
              (20...110).contains(triggerTemperatureCelsius) else {
            throw FanControlError.invalidConfiguration(
                "--temperature must be between 20 and 110 degrees Celsius"
            )
        }
        guard pollIntervalSeconds.isFinite,
              (0.5...5).contains(pollIntervalSeconds) else {
            throw FanControlError.invalidConfiguration(
                "--poll-interval must be between 0.5 and 5 seconds"
            )
        }
        guard hysteresisCelsius.isFinite,
              hysteresisCelsius >= 0,
              hysteresisCelsius < triggerTemperatureCelsius else {
            throw FanControlError.invalidConfiguration(
                "temperature hysteresis is invalid"
            )
        }

        self.speedPercent = speedPercent
        self.triggerTemperatureCelsius = triggerTemperatureCelsius
        self.pollIntervalSeconds = pollIntervalSeconds
        self.hysteresisCelsius = hysteresisCelsius
    }
}

public enum FanThermalPressure: String, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public struct FanCoolingSample: Sendable, Equatable {
    public let inferenceActive: Bool
    public let hottestTemperatureCelsius: Double?
    public let hottestSensor: String?
    public let thermalPressure: FanThermalPressure

    public init(
        inferenceActive: Bool,
        hottestTemperatureCelsius: Double?,
        hottestSensor: String? = nil,
        thermalPressure: FanThermalPressure
    ) {
        self.inferenceActive = inferenceActive
        self.hottestTemperatureCelsius = hottestTemperatureCelsius
        self.hottestSensor = hottestSensor
        self.thermalPressure = thermalPressure
    }
}

public enum FanCoolingReleaseReason: String, Sendable, Equatable {
    case providerIdle
    case cooled
    case temperatureUnavailable
    case systemThermalPressure
    case leaseExpired
    case stopped
}

public struct FanLeaseStatus: Sendable, Equatable {
    public let engaged: Bool
    public let temperatureCelsius: Double?
    public let temperatureSensor: String?
    public let targetRPMs: [Int]

    public init(
        engaged: Bool,
        temperatureCelsius: Double?,
        temperatureSensor: String?,
        targetRPMs: [Int]
    ) {
        self.engaged = engaged
        self.temperatureCelsius = temperatureCelsius
        self.temperatureSensor = temperatureSensor
        self.targetRPMs = targetRPMs
    }
}
