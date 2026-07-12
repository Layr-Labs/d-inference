import Foundation

public struct FanPolicyConfiguration: Equatable, Codable, Sendable {
    public static let minimumSpeedPercent = 60.0
    public static let maximumSpeedPercent = 90.0

    public let triggerCelsius: Double
    public let releaseCelsius: Double
    public let speedPercent: Double
    public let engageSampleCount: Int
    public let releaseSampleCount: Int

    public static let defaults = FanPolicyConfiguration(
        knownValidTrigger: 45,
        release: 40,
        speed: 80,
        engageSamples: 3,
        releaseSamples: 30
    )

    private init(
        knownValidTrigger trigger: Double,
        release: Double,
        speed: Double,
        engageSamples: Int,
        releaseSamples: Int
    ) {
        self.triggerCelsius = trigger
        self.releaseCelsius = release
        self.speedPercent = speed
        self.engageSampleCount = engageSamples
        self.releaseSampleCount = releaseSamples
    }

    public init(
        triggerCelsius: Double = 45,
        releaseCelsius: Double = 40,
        speedPercent: Double = 80,
        engageSampleCount: Int = 3,
        releaseSampleCount: Int = 30
    ) throws {
        guard triggerCelsius.isFinite, releaseCelsius.isFinite,
              FanHardwareReader.plausibleTemperatureRange.contains(triggerCelsius),
              FanHardwareReader.plausibleTemperatureRange.contains(releaseCelsius),
              releaseCelsius < triggerCelsius
        else {
            throw FanPolicyConfigurationError.invalidTemperatureThresholds(
                trigger: triggerCelsius,
                release: releaseCelsius
            )
        }
        guard speedPercent.isFinite,
              (Self.minimumSpeedPercent...Self.maximumSpeedPercent).contains(speedPercent)
        else {
            throw FanPolicyConfigurationError.invalidSpeedPercent(speedPercent)
        }
        guard engageSampleCount > 0, releaseSampleCount > 0 else {
            throw FanPolicyConfigurationError.invalidDebounceCounts(
                engage: engageSampleCount,
                release: releaseSampleCount
            )
        }
        self.triggerCelsius = triggerCelsius
        self.releaseCelsius = releaseCelsius
        self.speedPercent = speedPercent
        self.engageSampleCount = engageSampleCount
        self.releaseSampleCount = releaseSampleCount
    }

    private enum CodingKeys: String, CodingKey {
        case triggerCelsius
        case releaseCelsius
        case speedPercent
        case engageSampleCount
        case releaseSampleCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            triggerCelsius: try container.decodeIfPresent(
                Double.self,
                forKey: .triggerCelsius
            ) ?? 45,
            releaseCelsius: try container.decodeIfPresent(
                Double.self,
                forKey: .releaseCelsius
            ) ?? 40,
            speedPercent: try container.decodeIfPresent(
                Double.self,
                forKey: .speedPercent
            ) ?? 80,
            engageSampleCount: try container.decodeIfPresent(
                Int.self,
                forKey: .engageSampleCount
            ) ?? 3,
            releaseSampleCount: try container.decodeIfPresent(
                Int.self,
                forKey: .releaseSampleCount
            ) ?? 30
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(triggerCelsius, forKey: .triggerCelsius)
        try container.encode(releaseCelsius, forKey: .releaseCelsius)
        try container.encode(speedPercent, forKey: .speedPercent)
        try container.encode(engageSampleCount, forKey: .engageSampleCount)
        try container.encode(releaseSampleCount, forKey: .releaseSampleCount)
    }
}

public enum FanPolicyConfigurationError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalidTemperatureThresholds(trigger: Double, release: Double)
    case invalidSpeedPercent(Double)
    case invalidDebounceCounts(engage: Int, release: Int)

    public var description: String {
        switch self {
        case .invalidTemperatureThresholds(let trigger, let release):
            return "fan release temperature must be plausible and below trigger (trigger=\(trigger), release=\(release))"
        case .invalidSpeedPercent(let speed):
            return "fan speed must be between 60 and 90 percent (got \(speed))"
        case .invalidDebounceCounts(let engage, let release):
            return "fan debounce counts must be positive (engage=\(engage), release=\(release))"
        }
    }
}

public enum FanPolicyMode: String, Equatable, Codable, Sendable {
    case automatic
    case manual
}

public enum FanPolicyReason: Equatable, Codable, Sendable {
    case providerInactive
    case sensorUnavailable
    case invalidSensorValue
    case controlFailure
    case waitingForTrigger(samples: Int, required: Int)
    case belowTrigger
    case releaseReached
}

public enum FanPolicyAction: Equatable, Codable, Sendable {
    case stayAutomatic(reason: FanPolicyReason)
    case engage(speedPercent: Double, hottestGPUCelsius: Double)
    case maintain(speedPercent: Double, hottestGPUCelsius: Double)
    case restoreAutomatic(reason: FanPolicyReason)
}

public struct FanPolicyInput: Equatable, Sendable {
    public let providerLeaseActive: Bool
    public let gpuTemperaturesCelsius: [Double]?
    public let controlHealthy: Bool

    public init(
        providerLeaseActive: Bool,
        gpuTemperaturesCelsius: [Double]?,
        controlHealthy: Bool = true
    ) {
        self.providerLeaseActive = providerLeaseActive
        self.gpuTemperaturesCelsius = gpuTemperaturesCelsius
        self.controlHealthy = controlHealthy
    }
}

public struct FanPolicyStateMachine: Equatable, Sendable {
    public let configuration: FanPolicyConfiguration
    public private(set) var mode: FanPolicyMode = .automatic
    public private(set) var consecutiveHotSamples = 0
    public private(set) var consecutiveCoolSamples = 0

    public init(configuration: FanPolicyConfiguration = .defaults) {
        self.configuration = configuration
    }

    public mutating func evaluate(_ input: FanPolicyInput) -> FanPolicyAction {
        guard input.providerLeaseActive else {
            return forceAutomatic(reason: .providerInactive)
        }
        guard input.controlHealthy else {
            return forceAutomatic(reason: .controlFailure)
        }
        guard let temperatures = input.gpuTemperaturesCelsius, !temperatures.isEmpty else {
            return forceAutomatic(reason: .sensorUnavailable)
        }
        guard temperatures.allSatisfy({
            $0.isFinite && FanHardwareReader.plausibleTemperatureRange.contains($0)
        }) else {
            return forceAutomatic(reason: .invalidSensorValue)
        }

        guard let hottest = temperatures.max() else {
            return forceAutomatic(reason: .sensorUnavailable)
        }
        switch mode {
        case .automatic:
            consecutiveCoolSamples = 0
            guard hottest >= configuration.triggerCelsius else {
                consecutiveHotSamples = 0
                return .stayAutomatic(reason: .belowTrigger)
            }
            consecutiveHotSamples += 1
            guard consecutiveHotSamples >= configuration.engageSampleCount else {
                return .stayAutomatic(reason: .waitingForTrigger(
                    samples: consecutiveHotSamples,
                    required: configuration.engageSampleCount
                ))
            }
            mode = .manual
            consecutiveHotSamples = 0
            return .engage(
                speedPercent: configuration.speedPercent,
                hottestGPUCelsius: hottest
            )

        case .manual:
            consecutiveHotSamples = 0
            guard hottest <= configuration.releaseCelsius else {
                consecutiveCoolSamples = 0
                return .maintain(
                    speedPercent: configuration.speedPercent,
                    hottestGPUCelsius: hottest
                )
            }
            consecutiveCoolSamples += 1
            guard consecutiveCoolSamples >= configuration.releaseSampleCount else {
                return .maintain(
                    speedPercent: configuration.speedPercent,
                    hottestGPUCelsius: hottest
                )
            }
            mode = .automatic
            consecutiveCoolSamples = 0
            return .restoreAutomatic(reason: .releaseReached)
        }
    }

    public mutating func reset() -> FanPolicyAction {
        forceAutomatic(reason: .providerInactive)
    }

    private mutating func forceAutomatic(reason: FanPolicyReason) -> FanPolicyAction {
        consecutiveHotSamples = 0
        consecutiveCoolSamples = 0
        if mode == .manual {
            mode = .automatic
            return .restoreAutomatic(reason: reason)
        }
        return .stayAutomatic(reason: reason)
    }
}
