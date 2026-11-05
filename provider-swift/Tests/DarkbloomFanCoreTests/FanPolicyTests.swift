import Foundation
import Testing

@testable import DarkbloomFanCore

@Suite("Fan temperature policy")
struct FanPolicyTests {
    @Test("defaults pin the agreed trigger, release, speed, and debounce")
    func defaults() {
        let config = FanPolicyConfiguration.defaults
        #expect(config.triggerCelsius == 45)
        #expect(config.releaseCelsius == 40)
        #expect(config.speedPercent == 80)
        #expect(config.engageSampleCount == 3)
        #expect(config.releaseSampleCount == 30)
    }

    @Test("normal speed is restricted to 60 through 90 percent")
    func speedValidation() throws {
        #expect(try FanPolicyConfiguration(speedPercent: 60).speedPercent == 60)
        #expect(try FanPolicyConfiguration(speedPercent: 90).speedPercent == 90)
        #expect(throws: FanPolicyConfigurationError.invalidSpeedPercent(59.9)) {
            _ = try FanPolicyConfiguration(speedPercent: 59.9)
        }
        #expect(throws: FanPolicyConfigurationError.invalidSpeedPercent(90.1)) {
            _ = try FanPolicyConfiguration(speedPercent: 90.1)
        }
    }

    @Test("decoded root policy is validated instead of bypassing invariants")
    func decodedConfigurationValidation() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(
            FanPolicyConfiguration.self,
            from: Data("{}".utf8)
        )
        #expect(defaults == .defaults)

        for malicious in [
            #"{"speedPercent":10}"#,
            #"{"triggerCelsius":45,"releaseCelsius":50}"#,
            #"{"engageSampleCount":0}"#,
            #"{"releaseSampleCount":-1}"#,
        ] {
            #expect(throws: (any Error).self) {
                _ = try decoder.decode(
                    FanPolicyConfiguration.self,
                    from: Data(malicious.utf8)
                )
            }
        }
    }

    @Test("provider lease gates engagement and resets hot debounce")
    func providerLeaseGate() throws {
        var policy = FanPolicyStateMachine(configuration: try FanPolicyConfiguration(
            engageSampleCount: 2,
            releaseSampleCount: 2
        ))
        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [50]
        )) == .stayAutomatic(reason: .waitingForTrigger(samples: 1, required: 2)))

        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: false,
            gpuTemperaturesCelsius: [50]
        )) == .stayAutomatic(reason: .providerInactive))
        #expect(policy.consecutiveHotSamples == 0)

        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [50]
        )) == .stayAutomatic(reason: .waitingForTrigger(samples: 1, required: 2)))
    }

    @Test("hottest validated GPU sensor drives debounced engagement")
    func hottestSensorEngages() throws {
        var policy = FanPolicyStateMachine(configuration: try FanPolicyConfiguration(
            speedPercent: 75,
            engageSampleCount: 3,
            releaseSampleCount: 2
        ))
        for sample in 1...2 {
            #expect(policy.evaluate(FanPolicyInput(
                providerLeaseActive: true,
                gpuTemperaturesCelsius: [41, 45, 44]
            )) == .stayAutomatic(reason: .waitingForTrigger(samples: sample, required: 3)))
        }
        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [42, 47, 43]
        )) == .engage(speedPercent: 75, hottestGPUCelsius: 47))
        #expect(policy.mode == .manual)
    }

    @Test("a cool interruption resets engagement debounce")
    func hotDebounceMustBeConsecutive() throws {
        var policy = FanPolicyStateMachine(configuration: try FanPolicyConfiguration(
            engageSampleCount: 2,
            releaseSampleCount: 2
        ))
        _ = policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [46]
        ))
        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [44.9]
        )) == .stayAutomatic(reason: .belowTrigger))
        #expect(policy.consecutiveHotSamples == 0)
    }

    @Test("40 C release uses consecutive samples and the 40-45 band holds")
    func releaseHysteresis() throws {
        var policy = FanPolicyStateMachine(configuration: try FanPolicyConfiguration(
            speedPercent: 80,
            engageSampleCount: 1,
            releaseSampleCount: 2
        ))
        _ = policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [45]
        ))
        #expect(policy.mode == .manual)

        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [42]
        )) == .maintain(speedPercent: 80, hottestGPUCelsius: 42))
        #expect(policy.consecutiveCoolSamples == 0)

        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [40]
        )) == .maintain(speedPercent: 80, hottestGPUCelsius: 40))
        #expect(policy.consecutiveCoolSamples == 1)
        #expect(policy.evaluate(FanPolicyInput(
            providerLeaseActive: true,
            gpuTemperaturesCelsius: [39]
        )) == .restoreAutomatic(reason: .releaseReached))
        #expect(policy.mode == .automatic)
    }

    @Test("lease loss, sensor loss, invalid data, and control failure all restore")
    func failSafeRestoration() throws {
        let failureInputs = [
            FanPolicyInput(providerLeaseActive: false, gpuTemperaturesCelsius: [50]),
            FanPolicyInput(providerLeaseActive: true, gpuTemperaturesCelsius: nil),
            FanPolicyInput(providerLeaseActive: true, gpuTemperaturesCelsius: []),
            FanPolicyInput(providerLeaseActive: true, gpuTemperaturesCelsius: [.nan]),
            FanPolicyInput(
                providerLeaseActive: true,
                gpuTemperaturesCelsius: [50],
                controlHealthy: false
            ),
        ]
        let expectedReasons: [FanPolicyReason] = [
            .providerInactive,
            .sensorUnavailable,
            .sensorUnavailable,
            .invalidSensorValue,
            .controlFailure,
        ]

        for (input, reason) in zip(failureInputs, expectedReasons) {
            var policy = FanPolicyStateMachine(configuration: try FanPolicyConfiguration(
                engageSampleCount: 1,
                releaseSampleCount: 1
            ))
            _ = policy.evaluate(FanPolicyInput(
                providerLeaseActive: true,
                gpuTemperaturesCelsius: [50]
            ))
            #expect(policy.mode == .manual)
            #expect(policy.evaluate(input) == .restoreAutomatic(reason: reason))
            #expect(policy.mode == .automatic)
        }
    }
}
