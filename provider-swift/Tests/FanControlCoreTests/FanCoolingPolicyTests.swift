import Foundation
import Testing

@testable import FanControlCore

@Suite("Fan cooling policy")
struct FanCoolingPolicyTests {
    private let configuration = try! FanCoolingConfiguration()

    @Test("defaults match the CLI contract")
    func defaults() {
        #expect(configuration.speedPercent == 90)
        #expect(configuration.triggerTemperatureCelsius == 40)
        #expect(configuration.pollIntervalSeconds == 2)
        #expect(configuration.hysteresisCelsius == 3)
    }

    @Test("configuration rejects unsafe or nonsensical values")
    func validatesConfiguration() {
        #expect(throws: FanControlError.self) {
            try FanCoolingConfiguration(speedPercent: 89)
        }
        #expect(throws: FanControlError.self) {
            try FanCoolingConfiguration(triggerTemperatureCelsius: 150)
        }
        #expect(throws: FanControlError.self) {
            try FanCoolingConfiguration(pollIntervalSeconds: 0.1)
        }
    }

    @Test("hot idle machine remains automatic")
    func idleDoesNotEngage() {
        let action = FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: false,
            sample: sample(active: false, temperature: 80)
        )
        #expect(action == .maintain)
    }

    @Test("active inference engages at the threshold")
    func engagesAtThreshold() {
        let action = FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: false,
            sample: sample(active: true, temperature: 40)
        )
        #expect(action == .engage)
    }

    @Test("hysteresis prevents fan-mode churn")
    func hysteresis() {
        let stillBoosted = FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: true,
            sample: sample(active: true, temperature: 38)
        )
        #expect(stillBoosted == .maintain)

        let cooled = FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: true,
            sample: sample(active: true, temperature: 37)
        )
        #expect(cooled == .release(.cooled))
    }

    @Test("idle, missing sensors, and OS thermal pressure release control")
    func failSafeReleases() {
        #expect(FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: true,
            sample: sample(active: false, temperature: 80)
        ) == .release(.providerIdle))

        #expect(FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: true,
            sample: sample(active: true, temperature: nil)
        ) == .release(.temperatureUnavailable))

        #expect(FanCoolingPolicy.decide(
            configuration: configuration,
            isBoosted: true,
            sample: sample(
                active: true,
                temperature: 80,
                pressure: .serious
            )
        ) == .release(.systemThermalPressure))
    }

    @Test("percentage maps to advertised maximum RPM")
    func plannedRPM() {
        #expect(FanCoolingPolicy.plannedRPM(
            minimumRPM: 2_000,
            maximumRPM: 6_000,
            speedPercent: 90
        ) == 5_400)
    }

    private func sample(
        active: Bool,
        temperature: Double?,
        pressure: FanThermalPressure = .nominal
    ) -> FanCoolingSample {
        FanCoolingSample(
            inferenceActive: active,
            hottestTemperatureCelsius: temperature,
            thermalPressure: pressure
        )
    }
}
