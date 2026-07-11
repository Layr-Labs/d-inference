import Foundation

enum FanCoolingPolicyAction: Equatable {
    case engage
    case maintain
    case release(FanCoolingReleaseReason)
}

enum FanCoolingPolicy {
    static func decide(
        configuration: FanCoolingConfiguration,
        isBoosted: Bool,
        sample: FanCoolingSample
    ) -> FanCoolingPolicyAction {
        guard sample.inferenceActive else {
            return isBoosted ? .release(.providerIdle) : .maintain
        }

        switch sample.thermalPressure {
        case .nominal, .fair:
            break
        case .serious, .critical, .unknown:
            return isBoosted ? .release(.systemThermalPressure) : .maintain
        }

        guard let temperature = sample.hottestTemperatureCelsius,
              temperature.isFinite else {
            return isBoosted ? .release(.temperatureUnavailable) : .maintain
        }

        if isBoosted {
            let releaseTemperature = configuration.triggerTemperatureCelsius
                - configuration.hysteresisCelsius
            return temperature <= releaseTemperature
                ? .release(.cooled)
                : .maintain
        }

        return temperature >= configuration.triggerTemperatureCelsius
            ? .engage
            : .maintain
    }

    static func plannedRPM(
        minimumRPM: Double,
        maximumRPM: Double,
        speedPercent: Double
    ) -> Int {
        let requested = maximumRPM * speedPercent / 100
        return Int(requested.rounded()).clamped(
            to: Int(minimumRPM.rounded())...Int(maximumRPM.rounded())
        )
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
