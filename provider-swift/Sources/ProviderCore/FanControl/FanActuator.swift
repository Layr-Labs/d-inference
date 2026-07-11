import Foundation

final class FanActuator {
    private static let fanTestKey = SMCKey("Ftst")
    private static let modeRetryInterval: TimeInterval = 0.1
    private static let modeUnlockDelay: TimeInterval = 3
    private static let modeUnlockTimeout: TimeInterval = 10

    private let smc: AppleSMC
    private let fans: [SMCFan]
    private let hasFanTestKey: Bool
    private var fanTestEnabledByUs = false
    private var mutationStarted = false
    private(set) var targetRPMs: [Int] = []
    private(set) var isControlling = false

    init(smc: AppleSMC, hardware: FanHardware) throws {
        self.smc = smc
        fans = hardware.fans
        hasFanTestKey = hardware.hasFanTestKey

        if hardware.initialFanTestValue != nil,
           hardware.initialFanTestValue != 0 {
            throw FanControlError.fanTestModeActive
        }
        for fan in fans {
            if fan.initialMode == 1 {
                throw FanControlError.fanAlreadyControlled(fan.index)
            }
            guard fan.initialMode == 0 || fan.initialMode == 3 else {
                throw FanControlError.invalidSMCData(
                    "\(fan.modeKey.name) has unknown mode \(fan.initialMode)"
                )
            }
        }
    }

    deinit {
        try? restoreAutomatic()
    }

    func plannedRPMs(speedPercent: Double) -> [Int] {
        fans.map {
            FanCoolingPolicy.plannedRPM(
                minimumRPM: $0.minimumRPM,
                maximumRPM: $0.maximumRPM,
                speedPercent: speedPercent
            )
        }
    }

    func engage(
        speedPercent: Double,
        shouldStop: () -> Bool
    ) throws -> [Int] {
        guard !isControlling else {
            try maintain(shouldStop: shouldStop)
            return targetRPMs
        }
        try assertUnclaimed()
        mutationStarted = true

        do {
            try engageManualModes(shouldStop: shouldStop)
            targetRPMs = try fans.map {
                try targetRPM(for: $0, speedPercent: speedPercent)
            }
            try applyTargets()
            isControlling = true
            return targetRPMs
        } catch let operationError {
            do {
                try restoreAutomatic()
            } catch let restoreError {
                throw FanControlError.operationAndRestoreFailed(
                    operation: operationError.localizedDescription,
                    restore: restoreError.localizedDescription
                )
            }
            throw operationError
        }
    }

    func maintain(shouldStop: () -> Bool) throws {
        guard isControlling else { return }
        if shouldStop() {
            throw FanControlError.interrupted
        }

        let modes = try fans.map { try readMode($0) }
        if modes.contains(where: { $0 != 1 }) {
            try engageManualModes(shouldStop: shouldStop)
        }

        for (fan, target) in zip(fans, targetRPMs) {
            let current = try smc.read(fan.targetKey).numeric
            let tolerance = max(25, Double(target) * 0.01)
            if current == nil || abs((current ?? 0) - Double(target)) > tolerance {
                try writeTarget(target, for: fan)
            }
        }
    }

    func restoreAutomatic() throws {
        guard mutationStarted || isControlling || fanTestEnabledByUs else {
            return
        }

        var failures: [String] = []
        for fan in fans {
            do {
                try writeAutomaticMode(for: fan)
            } catch {
                failures.append("\(fan.modeKey.name): \(error.localizedDescription)")
            }
        }

        if fanTestEnabledByUs {
            do {
                try smc.write(Self.fanTestKey, bytes: [0])
                let value = try smc.read(Self.fanTestKey).uint8
                if value != 0 {
                    failures.append("Ftst: write did not stick")
                }
            } catch {
                failures.append("Ftst: \(error.localizedDescription)")
            }
        }

        for fan in fans {
            do {
                if try readMode(fan) == 1 {
                    failures.append("\(fan.modeKey.name): still manual")
                }
            } catch {
                failures.append("\(fan.modeKey.name): verification failed")
            }
        }

        guard failures.isEmpty else {
            throw FanControlError.restoreFailed(failures)
        }

        targetRPMs = []
        isControlling = false
        mutationStarted = false
        fanTestEnabledByUs = false
    }

    static func forceAutomatic(smc: AppleSMC, hardware: FanHardware) throws {
        var failures: [String] = []
        for fan in hardware.fans {
            do {
                try smc.write(fan.modeKey, bytes: [0])
            } catch {
                failures.append("\(fan.modeKey.name): \(error.localizedDescription)")
            }
        }

        if hardware.hasFanTestKey {
            do {
                try smc.write(fanTestKey, bytes: [0])
            } catch {
                failures.append("Ftst: \(error.localizedDescription)")
            }
        }

        for fan in hardware.fans {
            do {
                if try smc.read(fan.modeKey).uint8 == 1 {
                    failures.append("\(fan.modeKey.name): still manual")
                }
            } catch {
                failures.append("\(fan.modeKey.name): verification failed")
            }
        }

        guard failures.isEmpty else {
            throw FanControlError.restoreFailed(failures)
        }
    }

    private func assertUnclaimed() throws {
        for fan in fans {
            if try readMode(fan) == 1 {
                throw FanControlError.fanAlreadyControlled(fan.index)
            }
        }
        if hasFanTestKey,
           let value = try smc.readIfPresent(Self.fanTestKey)?.uint8,
           value != 0 {
            throw FanControlError.fanTestModeActive
        }
    }

    private func engageManualModes(shouldStop: () -> Bool) throws {
        do {
            try setAllModesManual()
            return
        } catch {
            if case FanControlError.interrupted = error {
                throw error
            }
            guard hasFanTestKey else {
                throw error
            }
        }

        try smc.write(Self.fanTestKey, bytes: [1])
        fanTestEnabledByUs = true
        guard try smc.read(Self.fanTestKey).uint8 == 1 else {
            throw FanControlError.writeNotApplied(Self.fanTestKey.name)
        }
        try cancellableSleep(
            Self.modeUnlockDelay,
            shouldStop: shouldStop
        )

        let deadline = Date().addingTimeInterval(Self.modeUnlockTimeout)
        var lastError: Error = FanControlError.writeNotApplied("fan mode")
        while Date() < deadline {
            if shouldStop() {
                throw FanControlError.interrupted
            }
            do {
                try setAllModesManual()
                return
            } catch {
                lastError = error
            }
            try cancellableSleep(
                Self.modeRetryInterval,
                shouldStop: shouldStop
            )
        }
        throw lastError
    }

    private func setAllModesManual() throws {
        for fan in fans {
            try smc.write(fan.modeKey, bytes: [1])
        }
        Thread.sleep(forTimeInterval: Self.modeRetryInterval)
        for fan in fans {
            if try readMode(fan) != 1 {
                throw FanControlError.writeNotApplied(fan.modeKey.name)
            }
        }
    }

    private func targetRPM(
        for fan: SMCFan,
        speedPercent: Double
    ) throws -> Int {
        let requested = Double(FanCoolingPolicy.plannedRPM(
            minimumRPM: fan.minimumRPM,
            maximumRPM: fan.maximumRPM,
            speedPercent: speedPercent
        ))
        let actual = (try? smc.read(SMCKey("F\(fan.index)Ac")).numeric)
            ?? fan.initialActualRPM
        let existingTarget = (try? smc.read(fan.targetKey).numeric)
            ?? fan.initialTargetRPM
        return Int(
            min(
                fan.maximumRPM,
                max(
                    max(requested, actual),
                    max(existingTarget, fan.minimumRPM)
                )
            ).rounded()
        )
    }

    private func applyTargets() throws {
        for (fan, target) in zip(fans, targetRPMs) {
            try writeTarget(target, for: fan)
        }
    }

    private func writeTarget(_ target: Int, for fan: SMCFan) throws {
        let current = try smc.read(fan.targetKey)
        try smc.write(
            fan.targetKey,
            bytes: try current.encodeRPM(Double(target))
        )
        Thread.sleep(forTimeInterval: 0.05)
        guard let applied = try smc.read(fan.targetKey).numeric,
              abs(applied - Double(target)) <= max(25, Double(target) * 0.01) else {
            throw FanControlError.writeNotApplied(fan.targetKey.name)
        }
    }

    private func writeAutomaticMode(for fan: SMCFan) throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try smc.write(fan.modeKey, bytes: [0])
                Thread.sleep(forTimeInterval: Self.modeRetryInterval)
                if try readMode(fan) != 1 {
                    return
                }
                lastError = FanControlError.writeNotApplied(fan.modeKey.name)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FanControlError.writeNotApplied(fan.modeKey.name)
    }

    private func readMode(_ fan: SMCFan) throws -> UInt8 {
        let value = try smc.read(fan.modeKey)
        guard value.dataTypeName == "ui8 ", let mode = value.uint8 else {
            throw FanControlError.unsupportedSMCType(
                key: fan.modeKey.name,
                type: value.dataTypeName
            )
        }
        return mode
    }

    private func cancellableSleep(
        _ duration: TimeInterval,
        shouldStop: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if shouldStop() {
                throw FanControlError.interrupted
            }
            Thread.sleep(
                forTimeInterval: min(
                    Self.modeRetryInterval,
                    max(0, deadline.timeIntervalSinceNow)
                )
            )
        }
    }
}
