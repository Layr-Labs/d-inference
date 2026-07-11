import Foundation

final class FanActuator {
    private static let fanTestKey = SMCKey("Ftst")
    private static let modeRetryInterval: TimeInterval = 0.1
    private static let modeUnlockDelay: TimeInterval = 3
    private static let modeUnlockTimeout: TimeInterval = 10

    private let smc: SMCReadingWriting
    private let fans: [SMCFan]
    private let hasFanTestKey: Bool
    private var fanTestEnabledByUs = false
    private var mutationStarted = false
    private(set) var targetRPMs: [Int] = []
    private(set) var isControlling = false

    init(smc: SMCReadingWriting, hardware: FanHardware) throws {
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
            guard Self.isAutomaticMode(fan.initialMode) else {
                throw FanControlError.invalidSMCData(
                    "\(fan.modeKey.name) has unknown mode \(fan.initialMode)"
                )
            }
        }
    }

    deinit {
        try? restoreAutomatic()
    }

    func engage(
        speedPercent: Double,
        shouldStop: () -> Bool
    ) throws -> [Int] {
        if shouldStop() {
            throw FanControlError.interrupted
        }
        guard !isControlling else {
            try maintain(shouldStop: shouldStop)
            return targetRPMs
        }
        try assertUnclaimed()
        mutationStarted = true

        do {
            targetRPMs = try fans.map {
                try targetRPM(for: $0, speedPercent: speedPercent)
            }
            try engageManualModes(shouldStop: shouldStop)
            try applyTargets(shouldStop: shouldStop)
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
            relinquishOwnership()
            throw FanControlError.fanControlOwnershipLost
        }
        if hasFanTestKey {
            let expected: UInt8 = fanTestEnabledByUs ? 1 : 0
            if try smc.read(Self.fanTestKey).uint8 != expected {
                relinquishOwnership()
                throw FanControlError.fanControlOwnershipLost
            }
        }

        for index in fans.indices {
            let fan = fans[index]
            let target = targetRPMs[index]
            let current = try smc.read(fan.targetKey).numeric
            let tolerance = max(25, Double(target) * 0.01)
            guard let current,
                  current.isFinite,
                  abs(current - Double(target)) <= tolerance else {
                relinquishOwnership()
                throw FanControlError.fanControlOwnershipLost
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
                guard try smc.read(Self.fanTestKey).uint8 == 0 else {
                    throw FanControlError.writeNotApplied(Self.fanTestKey.name)
                }
            } catch {
                failures.append("Ftst: \(error.localizedDescription)")
            }
        }

        for fan in fans {
            do {
                let mode = try readMode(fan)
                if !Self.isAutomaticMode(mode) {
                    failures.append("\(fan.modeKey.name): mode \(mode)")
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

    static func forceAutomatic(
        smc: SMCReadingWriting,
        hardware: FanHardware
    ) throws {
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
                guard try smc.read(fanTestKey).uint8 == 0 else {
                    throw FanControlError.writeNotApplied(fanTestKey.name)
                }
            } catch {
                failures.append("Ftst: \(error.localizedDescription)")
            }
        }

        Thread.sleep(forTimeInterval: modeRetryInterval)
        for fan in hardware.fans {
            do {
                let value = try smc.read(fan.modeKey)
                guard value.dataTypeName == "ui8 ",
                      let mode = value.uint8,
                      isAutomaticMode(mode) else {
                    failures.append("\(fan.modeKey.name): not automatic")
                    continue
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
            try setAllModesManual(shouldStop: shouldStop)
            return
        } catch let directError {
            if case FanControlError.interrupted = directError {
                throw directError
            }
            guard hasFanTestKey, Self.isThermalManagerRejection(directError) else {
                throw directError
            }
        }

        fanTestEnabledByUs = true
        try smc.write(Self.fanTestKey, bytes: [1])
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
                try setAllModesManual(shouldStop: shouldStop)
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

    private func setAllModesManual(shouldStop: () -> Bool) throws {
        for fan in fans {
            if shouldStop() {
                throw FanControlError.interrupted
            }
            try smc.write(fan.modeKey, bytes: [1])
        }
        Thread.sleep(forTimeInterval: Self.modeRetryInterval)
        for fan in fans {
            if shouldStop() {
                throw FanControlError.interrupted
            }
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
        let actual = finiteRPM(
            try? smc.read(SMCKey("F\(fan.index)Ac")).numeric
        ) ?? fan.initialActualRPM
        let existingTarget = finiteRPM(
            try? smc.read(fan.targetKey).numeric
        ) ?? fan.initialTargetRPM
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

    private func applyTargets(shouldStop: () -> Bool) throws {
        for (fan, target) in zip(fans, targetRPMs) {
            if shouldStop() {
                throw FanControlError.interrupted
            }
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
              applied.isFinite,
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
                if Self.isAutomaticMode(try readMode(fan)) {
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

    private func finiteRPM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func relinquishOwnership() {
        targetRPMs = []
        isControlling = false
        mutationStarted = false
        fanTestEnabledByUs = false
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

    private static func isAutomaticMode(_ mode: UInt8) -> Bool {
        mode == 0 || mode == 3
    }

    private static func isThermalManagerRejection(_ error: Error) -> Bool {
        switch error {
        case FanControlError.smcRejected(_, 0x82),
             FanControlError.writeNotApplied(_):
            return true
        default:
            return false
        }
    }
}
