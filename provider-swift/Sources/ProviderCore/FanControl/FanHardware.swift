import Foundation

struct SMCFan: Sendable, Equatable {
    let index: Int
    let modeKey: SMCKey
    let targetKey: SMCKey
    let minimumRPM: Double
    let maximumRPM: Double
    let initialActualRPM: Double
    let initialTargetRPM: Double
    let initialMode: UInt8
}

struct SMCTemperatureSensor: Sendable, Equatable {
    let key: SMCKey
}

struct FanHardware: Sendable {
    let fans: [SMCFan]
    let temperatureSensors: [SMCTemperatureSensor]
    let hasFanTestKey: Bool
    let initialFanTestValue: UInt8?
}

struct FanTemperatureReading: Sendable, Equatable {
    let sensor: String
    let celsius: Double
}

enum FanHardwareDiscovery {
    private static let fanCountKey = SMCKey("FNum")
    private static let fanTestKey = SMCKey("Ftst")

    static func discover(on smc: AppleSMC, includeTemperatures: Bool) throws -> FanHardware {
        let fans = try discoverFans(on: smc)
        let fanTestValue = try readFanTestValue(on: smc)
        let sensors = includeTemperatures
            ? try discoverTemperatureSensors(on: smc)
            : []

        return FanHardware(
            fans: fans,
            temperatureSensors: sensors,
            hasFanTestKey: fanTestValue != nil,
            initialFanTestValue: fanTestValue
        )
    }

    static func discoverForReset(on smc: AppleSMC) throws -> FanHardware {
        let count = try fanCount(on: smc)
        let fans = try (0..<count).map { index in
            let mode = try resolveModeKey(index: index, on: smc)
            return SMCFan(
                index: index,
                modeKey: mode.key,
                targetKey: SMCKey("F\(index)Tg"),
                minimumRPM: 0,
                maximumRPM: 1,
                initialActualRPM: 0,
                initialTargetRPM: 0,
                initialMode: mode.value
            )
        }
        let fanTestValue = try readFanTestValue(on: smc)
        return FanHardware(
            fans: fans,
            temperatureSensors: [],
            hasFanTestKey: fanTestValue != nil,
            initialFanTestValue: fanTestValue
        )
    }

    static func hottestTemperature(
        on smc: AppleSMC,
        sensors: [SMCTemperatureSensor]
    ) -> FanTemperatureReading? {
        var hottest: FanTemperatureReading?
        for sensor in sensors {
            guard let value = try? smc.read(sensor.key),
                  let temperature = value.numeric,
                  plausibleTemperature(temperature) else {
                continue
            }
            if hottest == nil || temperature > hottest!.celsius {
                hottest = FanTemperatureReading(
                    sensor: sensor.key.name,
                    celsius: temperature
                )
            }
        }
        return hottest
    }

    private static func discoverFans(on smc: AppleSMC) throws -> [SMCFan] {
        let count = try fanCount(on: smc)
        return try (0..<count).map { index in
            let mode = try resolveModeKey(index: index, on: smc)
            let targetKey = SMCKey("F\(index)Tg")
            let minimum = try numericValue(
                SMCKey("F\(index)Mn"),
                on: smc
            )
            let maximum = try numericValue(
                SMCKey("F\(index)Mx"),
                on: smc
            )
            let actual = try numericValue(
                SMCKey("F\(index)Ac"),
                on: smc
            )
            let target = try smc.read(targetKey)
            guard target.dataTypeName == "flt " || target.dataTypeName == "fpe2",
                  let targetRPM = target.numeric else {
                throw FanControlError.unsupportedSMCType(
                    key: targetKey.name,
                    type: target.dataTypeName
                )
            }
            guard minimum.isFinite,
                  maximum.isFinite,
                  minimum >= 0,
                  maximum >= 1_000,
                  maximum <= 20_000,
                  minimum < maximum else {
                throw FanControlError.invalidSMCData(
                    "fan \(index) limits are \(minimum)-\(maximum) RPM"
                )
            }

            return SMCFan(
                index: index,
                modeKey: mode.key,
                targetKey: targetKey,
                minimumRPM: minimum,
                maximumRPM: maximum,
                initialActualRPM: actual,
                initialTargetRPM: targetRPM,
                initialMode: mode.value
            )
        }
    }

    private static func fanCount(on smc: AppleSMC) throws -> Int {
        let countValue = try smc.read(fanCountKey)
        guard countValue.dataTypeName == "ui8 ",
              let countByte = countValue.uint8 else {
            throw FanControlError.invalidSMCData(
                "FNum must be a one-byte ui8 value"
            )
        }

        let count = Int(countByte)
        guard count > 0 else {
            throw FanControlError.noFans
        }
        guard count <= 10 else {
            throw FanControlError.invalidFanCount(count)
        }
        return count
    }

    private static func resolveModeKey(
        index: Int,
        on smc: AppleSMC
    ) throws -> (key: SMCKey, value: UInt8) {
        let candidates = [
            SMCKey("F\(index)Md"),
            SMCKey("F\(index)md"),
        ]
        var matches: [(SMCKey, UInt8)] = []

        for key in candidates {
            guard let value = try smc.readIfPresent(key) else {
                continue
            }
            guard value.dataTypeName == "ui8 ", let mode = value.uint8 else {
                throw FanControlError.unsupportedSMCType(
                    key: key.name,
                    type: value.dataTypeName
                )
            }
            matches.append((key, mode))
        }

        guard !matches.isEmpty else {
            throw FanControlError.fanModeKeyMissing(index)
        }
        guard matches.count == 1 else {
            throw FanControlError.ambiguousFanModeKeys(index)
        }
        return matches[0]
    }

    private static func readFanTestValue(on smc: AppleSMC) throws -> UInt8? {
        guard let value = try smc.readIfPresent(fanTestKey) else {
            return nil
        }
        guard value.dataTypeName == "ui8 ", let flag = value.uint8 else {
            throw FanControlError.unsupportedSMCType(
                key: fanTestKey.name,
                type: value.dataTypeName
            )
        }
        return flag
    }

    private static func discoverTemperatureSensors(
        on smc: AppleSMC
    ) throws -> [SMCTemperatureSensor] {
        let count = try smc.keyCount()
        var sensors: [SMCTemperatureSensor] = []
        sensors.reserveCapacity(64)

        for index in 0..<count {
            guard let key = try? smc.key(at: index),
                  key.name.first == "T",
                  let value = try? smc.read(key),
                  value.dataTypeName == "flt " || value.dataTypeName == "sp78",
                  let temperature = value.numeric,
                  plausibleTemperature(temperature) else {
                continue
            }
            sensors.append(SMCTemperatureSensor(key: key))
        }

        guard !sensors.isEmpty else {
            throw FanControlError.noTemperatureSensors
        }
        return sensors
    }

    private static func numericValue(
        _ key: SMCKey,
        on smc: AppleSMC
    ) throws -> Double {
        let value = try smc.read(key)
        guard let number = value.numeric, number.isFinite else {
            throw FanControlError.unsupportedSMCType(
                key: key.name,
                type: value.dataTypeName
            )
        }
        return number
    }

    private static func plausibleTemperature(_ value: Double) -> Bool {
        value.isFinite && (5...125).contains(value)
    }
}
