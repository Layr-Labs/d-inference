import Testing

@testable import FanControlCore

@Suite("Fan actuator ownership")
struct FanActuatorTests {
    @Test("target drift relinquishes without overwriting another controller")
    func targetDriftRelinquishes() throws {
        let smc = FakeSMC()
        let actuator = try makeActuator(smc: smc)
        _ = try actuator.engage(speedPercent: 90, shouldStop: { false })
        let writesBeforeDrift = smc.writes.count
        smc.setRPM(3_000, for: "F0Tg")

        #expect(throws: FanControlError.self) {
            try actuator.maintain(shouldStop: { false })
        }

        #expect(!actuator.isControlling)
        #expect(smc.writes.count == writesBeforeDrift)
        #expect(try smc.read(SMCKey("F0Md")).uint8 == 1)
        #expect(try smc.read(SMCKey("F0Tg")).numeric == 3_000)
    }

    @Test("mode drift relinquishes without reacquiring manual mode")
    func modeDriftRelinquishes() throws {
        let smc = FakeSMC()
        let actuator = try makeActuator(smc: smc)
        _ = try actuator.engage(speedPercent: 90, shouldStop: { false })
        smc.setUInt8(0, for: "F0Md")
        let writesBeforeDrift = smc.writes.count

        #expect(throws: FanControlError.self) {
            try actuator.maintain(shouldStop: { false })
        }

        #expect(!actuator.isControlling)
        #expect(smc.writes.count == writesBeforeDrift)
        #expect(try smc.read(SMCKey("F0Md")).uint8 == 0)
    }

    @Test("a partial engagement restores automatic mode")
    func partialEngagementRestores() throws {
        let smc = FakeSMC()
        smc.failingWrites.insert(SMCKey("F0Tg"))
        let actuator = try makeActuator(smc: smc)

        #expect(throws: FanControlError.self) {
            try actuator.engage(speedPercent: 90, shouldStop: { false })
        }

        #expect(!actuator.isControlling)
        #expect(try smc.read(SMCKey("F0Md")).uint8 == 0)
        #expect(smc.writes.contains { $0.key.name == "F0Md" && $0.bytes == [1] })
        #expect(smc.writes.contains { $0.key.name == "F0Md" && $0.bytes == [0] })
    }

    private func makeActuator(smc: FakeSMC) throws -> FanActuator {
        smc.setUInt8(0, for: "F0Md")
        smc.setRPM(2_000, for: "F0Ac")
        smc.setRPM(2_000, for: "F0Tg")
        return try FanActuator(
            smc: smc,
            hardware: FanHardware(
                fans: [
                    SMCFan(
                        index: 0,
                        modeKey: SMCKey("F0Md"),
                        targetKey: SMCKey("F0Tg"),
                        minimumRPM: 2_000,
                        maximumRPM: 6_000,
                        initialActualRPM: 2_000,
                        initialTargetRPM: 2_000,
                        initialMode: 0
                    ),
                ],
                temperatureSensors: [],
                hasFanTestKey: false,
                initialFanTestValue: nil
            )
        )
    }
}

private final class FakeSMC: SMCReadingWriting {
    struct Write: Equatable {
        let key: SMCKey
        let bytes: [UInt8]
    }

    var failingWrites: Set<SMCKey> = []
    private(set) var writes: [Write] = []
    private var values: [SMCKey: SMCValue] = [:]

    func read(_ key: SMCKey) throws -> SMCValue {
        guard let value = values[key] else {
            throw FanControlError.smcKeyNotFound(key.name)
        }
        return value
    }

    func readIfPresent(_ key: SMCKey) throws -> SMCValue? {
        values[key]
    }

    func write(_ key: SMCKey, bytes: [UInt8]) throws {
        writes.append(Write(key: key, bytes: bytes))
        if failingWrites.contains(key) {
            throw FanControlError.writeNotApplied(key.name)
        }
        guard let current = values[key] else {
            throw FanControlError.smcKeyNotFound(key.name)
        }
        values[key] = SMCValue(
            key: key,
            dataType: current.dataType,
            bytes: bytes
        )
    }

    func setUInt8(_ value: UInt8, for name: String) {
        let key = SMCKey(name)
        values[key] = SMCValue(
            key: key,
            dataType: SMCKey("ui8 ").rawValue,
            bytes: [value]
        )
    }

    func setRPM(_ rpm: Double, for name: String) {
        let key = SMCKey(name)
        let bits = Float(rpm).bitPattern
        values[key] = SMCValue(
            key: key,
            dataType: SMCKey("flt ").rawValue,
            bytes: [
                UInt8(bits & 0xff),
                UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff),
                UInt8((bits >> 24) & 0xff),
            ]
        )
    }
}
