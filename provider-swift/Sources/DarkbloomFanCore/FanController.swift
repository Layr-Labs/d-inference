import Foundation

public struct FanControlTiming: Sendable {
    public let ftstSettleSeconds: TimeInterval
    public let retryDelaySeconds: TimeInterval
    public let manualModeAttempts: Int
    public let verificationAttempts: Int
    public let sleep: @Sendable (TimeInterval) -> Void

    public init(
        ftstSettleSeconds: TimeInterval = 0.5,
        retryDelaySeconds: TimeInterval = 0.1,
        manualModeAttempts: Int = 100,
        verificationAttempts: Int = 3,
        sleep: @escaping @Sendable (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        }
    ) {
        precondition(ftstSettleSeconds >= 0)
        precondition(retryDelaySeconds >= 0)
        precondition(manualModeAttempts > 0)
        precondition(verificationAttempts > 0)
        self.ftstSettleSeconds = ftstSettleSeconds
        self.retryDelaySeconds = retryDelaySeconds
        self.manualModeAttempts = manualModeAttempts
        self.verificationAttempts = verificationAttempts
        self.sleep = sleep
    }

    public static let production = FanControlTiming()
}

public struct FanControlSession: Equatable, Codable, Sendable {
    public let targetRPMByFan: [Int: Double]
    public let ownsFtst: Bool

    public init(targetRPMByFan: [Int: Double], ownsFtst: Bool) {
        self.targetRPMByFan = targetRPMByFan
        self.ownsFtst = ownsFtst
    }
}

/// Durable ownership boundary recorded immediately before a write that may
/// still land despite returning an error.
public struct FanControlOwnership: Equatable, Sendable {
    public let fanIndices: [Int]
    public let ownsFtst: Bool

    public init(fanIndices: [Int], ownsFtst: Bool) {
        self.fanIndices = Array(Set(fanIndices)).sorted()
        self.ownsFtst = ownsFtst
    }
}

public enum FanRollbackStep: String, Equatable, Codable, Sendable {
    case restoreMode
    case clearFtst
}

public enum FanRollbackError: Error, Equatable, Sendable, CustomStringConvertible {
    case smc(SMCError)
    case hardware(FanHardwareError)
    case modeNotAutomatic(rawValue: UInt8)
    case ftstStillSet(rawValue: UInt8)

    public var description: String {
        switch self {
        case .smc(let error): return error.description
        case .hardware(let error): return error.description
        case .modeNotAutomatic(let value): return "fan mode remained \(value)"
        case .ftstStillSet(let value): return "Ftst remained \(value)"
        }
    }
}

public struct FanRollbackFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let fanIndex: Int?
    public let step: FanRollbackStep
    public let error: FanRollbackError

    public init(fanIndex: Int?, step: FanRollbackStep, error: FanRollbackError) {
        self.fanIndex = fanIndex
        self.step = step
        self.error = error
    }

    public var description: String {
        "\(step.rawValue) \(fanIndex.map { "fan \($0)" } ?? "global"): \(error)"
    }
}

public indirect enum FanControllerError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case noFans
    case invalidSpeedPercent(Double)
    case alreadyControlling
    case notControlling
    case incompleteSession(index: Int)
    case duplicateFanIndex(Int)
    case foreignManualControl(indices: [Int])
    case unknownFanMode(index: Int, rawValue: UInt8)
    case foreignFtst(rawValue: UInt8)
    case takeoverFloorExceedsMaximum(index: Int, floor: Double, maximum: Double)
    case modeVerificationFailed(index: Int, rawValue: UInt8)
    case targetVerificationFailed(index: Int, expected: Double, actual: Double)
    case manualModeTimeout(index: Int, lastError: SMCError?)
    case hardware(FanHardwareError)
    case smc(SMCError)
    case rollbackFailed(primary: FanControllerError, failures: [FanRollbackFailure])

    public var description: String {
        switch self {
        case .noFans:
            return "this Mac reports no controllable fans"
        case .invalidSpeedPercent(let speed):
            return "fan speed must be between 60 and 90 percent (got \(speed))"
        case .alreadyControlling:
            return "Darkbloom already owns a manual fan session"
        case .notControlling:
            return "Darkbloom does not own a manual fan session"
        case .incompleteSession(let index):
            return "Darkbloom has no stored target for tracked fan \(index)"
        case .duplicateFanIndex(let index):
            return "fan inventory contains duplicate index \(index)"
        case .foreignManualControl(let indices):
            return "refusing to replace foreign manual control of fans \(indices)"
        case .unknownFanMode(let index, let rawValue):
            return "fan \(index) reported unknown mode \(rawValue)"
        case .foreignFtst(let rawValue):
            return "refusing to claim pre-existing Ftst value \(rawValue)"
        case .takeoverFloorExceedsMaximum(let index, let floor, let maximum):
            return "fan \(index) takeover floor \(floor) exceeds maximum \(maximum)"
        case .modeVerificationFailed(let index, let rawValue):
            return "fan \(index) did not enter manual mode (read \(rawValue))"
        case .targetVerificationFailed(let index, let expected, let actual):
            return "fan \(index) target verification failed (expected \(expected), read \(actual))"
        case .manualModeTimeout(let index, let lastError):
            return "fan \(index) did not enter manual mode before timeout: \(lastError?.description ?? "no error")"
        case .hardware(let error):
            return error.description
        case .smc(let error):
            return error.description
        case .rollbackFailed(let primary, let failures):
            return "fan operation failed (\(primary)); rollback also failed: \(failures.map(\.description).joined(separator: "; "))"
        }
    }
}

public actor TransactionalFanController {
    private static let targetToleranceRPM = 1.0

    private let backend: any SMCBackend
    private let inventory: FanInventory
    private let reader: FanHardwareReader
    private let timing: FanControlTiming

    // A fan enters this map before its first possible mode write. Retaining it
    // after a failed rollback lets a later restore retry repair uncertain state.
    private var possiblyControlledFans: [Int: FanCapability] = [:]
    private var targetRPMByFan: [Int: Double] = [:]
    private var mayOwnFtst = false

    public init(
        backend: any SMCBackend,
        inventory: FanInventory,
        timing: FanControlTiming = .production
    ) {
        self.backend = backend
        self.inventory = inventory
        self.reader = FanHardwareReader(backend: backend)
        self.timing = timing
    }

    public var isControlling: Bool {
        !possiblyControlledFans.isEmpty || mayOwnFtst
    }

    public func currentSession() -> FanControlSession? {
        guard isControlling else { return nil }
        return FanControlSession(
            targetRPMByFan: targetRPMByFan,
            ownsFtst: mayOwnFtst
        )
    }

    @discardableResult
    public func engage(
        speedPercent: Double,
        recordOwnership: @Sendable (FanControlOwnership) throws -> Void = { _ in }
    ) throws -> FanControlSession {
        let allowedSpeed = FanPolicyConfiguration.minimumSpeedPercent...FanPolicyConfiguration.maximumSpeedPercent
        guard speedPercent.isFinite,
              allowedSpeed.contains(speedPercent)
        else {
            throw FanControllerError.invalidSpeedPercent(speedPercent)
        }
        guard !isControlling else {
            throw FanControllerError.alreadyControlling
        }
        guard !inventory.fans.isEmpty else {
            throw FanControllerError.noFans
        }

        let readings: [FanReading]
        do {
            readings = try reader.fanReadings(in: inventory)
        } catch {
            throw normalize(error)
        }
        let foreign = readings.compactMap { $0.mode == .manual ? $0.capability.index : nil }
        guard foreign.isEmpty else {
            throw FanControllerError.foreignManualControl(indices: foreign.sorted())
        }
        for reading in readings {
            if case .unknown(let rawValue) = reading.mode {
                throw FanControllerError.unknownFanMode(
                    index: reading.capability.index,
                    rawValue: rawValue
                )
            }
        }
        var seenFanIndices = Set<Int>()
        for reading in readings where !seenFanIndices.insert(reading.capability.index).inserted {
            throw FanControllerError.duplicateFanIndex(reading.capability.index)
        }
        if let ftstKey = inventory.ftstKey {
            let rawFtst = try readUI8(ftstKey)
            guard rawFtst == 0 else {
                throw FanControllerError.foreignFtst(rawValue: rawFtst)
            }
        }

        var targets: [Int: Double] = [:]
        for reading in readings {
            let takeoverFloor = max(
                reading.minimumRPM,
                max(reading.actualRPM, reading.targetRPM)
            )
            guard takeoverFloor <= reading.maximumRPM else {
                throw FanControllerError.takeoverFloorExceedsMaximum(
                    index: reading.capability.index,
                    floor: takeoverFloor,
                    maximum: reading.maximumRPM
                )
            }
            let requested = reading.maximumRPM * speedPercent / 100.0
            targets[reading.capability.index] = min(
                reading.maximumRPM,
                max(requested, takeoverFloor)
            )
        }

        do {
            for reading in readings {
                let fan = reading.capability
                // Close the initial-scan race, then durably widen ownership only
                // for this fan. Recheck after the journal fsync so a foreign
                // claimant that arrived during the write is not overwritten.
                try verifyAvailableForTakeover(fan)
                let priorOwnership = currentOwnership()
                try recordOwnership(currentOwnership(including: fan.index))
                do {
                    try verifyAvailableForTakeover(fan)
                } catch {
                    try recordOwnership(priorOwnership)
                    throw error
                }

                // Mark in-memory intent before the first mode write. A backend
                // can fail after the kernel accepted it, so "threw" is not proof
                // that the fan stayed automatic.
                possiblyControlledFans[fan.index] = fan
                do {
                    try writeAndVerifyManualMode(fan)
                } catch {
                    let directFailure = normalize(error)
                    guard shouldAttemptFtst(after: directFailure) else {
                        throw directFailure
                    }
                    try acquireFtstIfNeeded(recordOwnership: recordOwnership)
                    try retryManualMode(fan)
                }
                guard let target = targets[fan.index] else {
                    throw FanControllerError.incompleteSession(index: fan.index)
                }
                try writeAndVerifyTarget(fan, rpm: target)
                targetRPMByFan[fan.index] = target
            }

            try verifyFtstOwnershipAtTransactionEnd(
                recordOwnership: recordOwnership
            )

            return FanControlSession(
                targetRPMByFan: targetRPMByFan,
                ownsFtst: mayOwnFtst
            )
        } catch {
            let primary = normalize(error)
            let failures = restoreTrackedState()
            if !failures.isEmpty {
                throw FanControllerError.rollbackFailed(
                    primary: primary,
                    failures: failures
                )
            }
            throw primary
        }
    }

    public func restoreAutomatic() throws {
        let failures = restoreTrackedState()
        if !failures.isEmpty {
            throw FanControllerError.rollbackFailed(
                primary: .smc(.injectedFailure("explicit automatic restore")),
                failures: failures
            )
        }
    }

    /// Reconcile a live session after firmware or thermalmonitord reclaimed a
    /// fan mode/target (commonly across sleep/wake). Calls are actor-serialized
    /// with engage/restore. Any failure restores every tracked fan to automatic
    /// control rather than leaving a partially repaired session active.
    @discardableResult
    public func maintain(
        recordOwnership: @Sendable (FanControlOwnership) throws -> Void = { _ in }
    ) throws -> FanControlSession {
        guard isControlling else {
            throw FanControllerError.notControlling
        }
        guard !possiblyControlledFans.isEmpty else {
            let failures = restoreTrackedState()
            if !failures.isEmpty {
                throw FanControllerError.rollbackFailed(
                    primary: .notControlling,
                    failures: failures
                )
            }
            throw FanControllerError.notControlling
        }

        do {
            for fan in possiblyControlledFans.values where targetRPMByFan[fan.index] == nil {
                throw FanControllerError.incompleteSession(index: fan.index)
            }
            // Sleep can reset Ftst even before the per-fan mode read changes.
            // Reassert a gate that this session already owns before touching
            // individual modes.
            if mayOwnFtst {
                try acquireFtstIfNeeded(recordOwnership: recordOwnership)
            }

            for fan in possiblyControlledFans.values.sorted(by: { $0.index < $1.index }) {
                let savedTarget = targetRPMByFan[fan.index]!
                let rawMode = try readUI8(fan.modeKey)
                switch FanMode(rawValue: rawMode) {
                case .manual:
                    break
                case .automatic, .system:
                    do {
                        try writeAndVerifyManualMode(fan)
                    } catch {
                        let directFailure = normalize(error)
                        guard shouldAttemptFtst(after: directFailure) else {
                            throw directFailure
                        }
                        try acquireFtstIfNeeded(recordOwnership: recordOwnership)
                        try retryManualMode(fan)
                    }
                case .unknown(let value):
                    throw FanControllerError.unknownFanMode(
                        index: fan.index,
                        rawValue: value
                    )
                }

                // Never reduce cooling during maintenance. Firmware or an
                // operator may have raised the live target while this session
                // remained manual; adopt that higher value as the new floor.
                let liveTarget = try readRPM(fan.targetKey, fanIndex: fan.index)
                let maximum = try maximumRPM(for: fan)
                guard liveTarget <= maximum else {
                    throw FanControllerError.takeoverFloorExceedsMaximum(
                        index: fan.index,
                        floor: liveTarget,
                        maximum: maximum
                    )
                }
                let maintainedTarget = max(savedTarget, liveTarget)
                targetRPMByFan[fan.index] = maintainedTarget
                if abs(liveTarget - maintainedTarget) > Self.targetToleranceRPM {
                    try writeAndVerifyTarget(fan, rpm: maintainedTarget)
                }
            }
            try verifyFtstOwnershipAtTransactionEnd(
                recordOwnership: recordOwnership
            )

            return FanControlSession(
                targetRPMByFan: targetRPMByFan,
                ownsFtst: mayOwnFtst
            )
        } catch {
            let primary = normalize(error)
            let failures = restoreTrackedState()
            if !failures.isEmpty {
                throw FanControllerError.rollbackFailed(
                    primary: primary,
                    failures: failures
                )
            }
            throw primary
        }
    }

    @discardableResult
    public func reassert() throws -> FanControlSession {
        try maintain()
    }

    private func writeAndVerifyManualMode(_ fan: FanCapability) throws {
        do {
            try backend.write(fan.modeKey, bytes: [FanMode.manual.rawValue])
            let raw = try readUI8(fan.modeKey)
            guard raw == FanMode.manual.rawValue else {
                throw FanControllerError.modeVerificationFailed(
                    index: fan.index,
                    rawValue: raw
                )
            }
        } catch {
            throw normalize(error)
        }
    }

    private func retryManualMode(_ fan: FanCapability) throws {
        var lastError: SMCError?
        for attempt in 0..<timing.manualModeAttempts {
            do {
                try writeAndVerifyManualMode(fan)
                return
            } catch let error as FanControllerError {
                if case .smc(let smcError) = error {
                    lastError = smcError
                    if smcError.isNotPrivileged || smcError.isKeyNotFound {
                        throw error
                    }
                } else if case .modeVerificationFailed = error {
                    lastError = nil
                } else {
                    throw error
                }
            }
            if attempt + 1 < timing.manualModeAttempts {
                timing.sleep(timing.retryDelaySeconds)
            }
        }
        throw FanControllerError.manualModeTimeout(
            index: fan.index,
            lastError: lastError
        )
    }

    private func acquireFtstIfNeeded(
        recordOwnership: @Sendable (FanControlOwnership) throws -> Void
    ) throws {
        guard let ftstKey = inventory.ftstKey else {
            throw FanControllerError.smc(.keyNotFound("Ftst"))
        }
        let initial = try readUI8(ftstKey)
        if mayOwnFtst, initial == 1 {
            return
        }
        if initial != 0 {
            throw FanControllerError.foreignFtst(rawValue: initial)
        }

        // The caller durably records possible ownership only after we know the
        // gate is free, immediately before the first write that may still land
        // despite throwing. Then mirror that intent in memory for rollback.
        try recordOwnership(currentOwnership(ownsFtst: true))
        mayOwnFtst = true
        do {
            try backend.write(ftstKey, bytes: [1])
            // M3-class firmware applies Ftst asynchronously (and some builds
            // expose it as an edge-trigger that still reads zero). The ensuing
            // verified manual-mode transition is the authoritative proof.
            timing.sleep(timing.ftstSettleSeconds)
            let actual = try readUI8(ftstKey)
            guard actual == 0 || actual == 1 else {
                throw SMCError.firmwareRejected(
                    operation: .writeBytes,
                    key: ftstKey,
                    result: actual
                )
            }
        } catch {
            throw normalize(error)
        }
    }

    private func verifyFtstOwnershipAtTransactionEnd(
        recordOwnership: @Sendable (FanControlOwnership) throws -> Void
    ) throws {
        guard let ftstKey = inventory.ftstKey else { return }
        if mayOwnFtst {
            let current = try readUI8(ftstKey)
            guard current == 0 || current == 1 else {
                throw FanControllerError.foreignFtst(rawValue: current)
            }
            if current == 0 {
                try recordOwnership(currentOwnership(ownsFtst: true))
                try backend.write(ftstKey, bytes: [1])
                timing.sleep(timing.ftstSettleSeconds)
                let refreshed = try readUI8(ftstKey)
                guard refreshed == 0 || refreshed == 1 else {
                    throw FanControllerError.foreignFtst(rawValue: refreshed)
                }
            }
            return
        }
        let rawFtst = try readUI8(ftstKey)
        guard rawFtst == 0 else {
            throw FanControllerError.foreignFtst(rawValue: rawFtst)
        }
    }

    private func verifyAvailableForTakeover(_ fan: FanCapability) throws {
        let rawMode = try readUI8(fan.modeKey)
        switch FanMode(rawValue: rawMode) {
        case .automatic, .system:
            return
        case .manual:
            throw FanControllerError.foreignManualControl(indices: [fan.index])
        case .unknown(let value):
            throw FanControllerError.unknownFanMode(
                index: fan.index,
                rawValue: value
            )
        }
    }

    private func currentOwnership(
        including fanIndex: Int? = nil,
        ownsFtst: Bool? = nil
    ) -> FanControlOwnership {
        var fanIndices = Set(possiblyControlledFans.keys)
        if let fanIndex {
            fanIndices.insert(fanIndex)
        }
        return FanControlOwnership(
            fanIndices: Array(fanIndices),
            ownsFtst: ownsFtst ?? mayOwnFtst
        )
    }

    private func writeAndVerifyTarget(_ fan: FanCapability, rpm: Double) throws {
        let bytes: [UInt8]
        do {
            bytes = try SMCValue.float32Bytes(rpm, key: fan.targetKey)
            try backend.write(fan.targetKey, bytes: bytes)
        } catch {
            throw normalize(error)
        }

        var actual = Double.nan
        for attempt in 0..<timing.verificationAttempts {
            do {
                actual = try backend.read(fan.targetKey).float32()
            } catch {
                throw normalize(error)
            }
            if abs(actual - rpm) <= Self.targetToleranceRPM {
                return
            }
            if attempt + 1 < timing.verificationAttempts {
                timing.sleep(timing.retryDelaySeconds)
            }
        }
        throw FanControllerError.targetVerificationFailed(
            index: fan.index,
            expected: rpm,
            actual: actual
        )
    }

    private func restoreTrackedState() -> [FanRollbackFailure] {
        var failures: [FanRollbackFailure] = []
        var stillUncertain: [Int: FanCapability] = [:]

        for fan in possiblyControlledFans.values.sorted(by: { $0.index < $1.index }) {
            do {
                try backend.write(fan.modeKey, bytes: [FanMode.automatic.rawValue])
                let raw = try readUI8(fan.modeKey)
                guard FanMode(rawValue: raw).isAutomatic else {
                    throw FanRollbackError.modeNotAutomatic(rawValue: raw)
                }
                // Auto mode is authoritative. Clearing the stale manual target
                // is best-effort defense against a later accidental mode toggle;
                // failure here must not turn a verified Auto restore into error.
                if let zero = try? SMCValue.float32Bytes(0, key: fan.targetKey) {
                    try? backend.write(fan.targetKey, bytes: zero)
                }
            } catch {
                let rollbackError = normalizeRollback(error)
                failures.append(FanRollbackFailure(
                    fanIndex: fan.index,
                    step: .restoreMode,
                    error: rollbackError
                ))
                stillUncertain[fan.index] = fan
            }
        }

        var ftstStillUncertain = false
        if mayOwnFtst, let ftstKey = inventory.ftstKey {
            do {
                try backend.write(ftstKey, bytes: [0])
                let raw = try readUI8(ftstKey)
                guard raw == 0 else {
                    throw FanRollbackError.ftstStillSet(rawValue: raw)
                }
            } catch {
                failures.append(FanRollbackFailure(
                    fanIndex: nil,
                    step: .clearFtst,
                    error: normalizeRollback(error)
                ))
                ftstStillUncertain = true
            }
        } else if mayOwnFtst {
            failures.append(FanRollbackFailure(
                fanIndex: nil,
                step: .clearFtst,
                error: .smc(.keyNotFound("Ftst"))
            ))
            ftstStillUncertain = true
        }

        possiblyControlledFans = stillUncertain
        targetRPMByFan = targetRPMByFan.filter { stillUncertain[$0.key] != nil }
        mayOwnFtst = ftstStillUncertain
        return failures
    }

    private func readUI8(_ key: SMCKey) throws -> UInt8 {
        do {
            return try backend.read(key).uint8()
        } catch {
            throw normalize(error)
        }
    }

    private func maximumRPM(for fan: FanCapability) throws -> Double {
        if let cached = inventory.fanLimits[fan.index]?.maximumRPM {
            return cached
        }
        return try readRPM(fan.maximumKey, fanIndex: fan.index)
    }

    private func readRPM(_ key: SMCKey, fanIndex: Int) throws -> Double {
        do {
            let rpm = try backend.read(key).float32()
            guard rpm.isFinite, rpm >= 0 else {
                throw FanHardwareError.invalidFanRPM(
                    index: fanIndex,
                    field: key.rawValue,
                    value: rpm
                )
            }
            return rpm
        } catch {
            throw normalize(error)
        }
    }

    private func shouldAttemptFtst(after error: FanControllerError) -> Bool {
        switch error {
        case .modeVerificationFailed:
            return inventory.ftstKey != nil
        case .smc(let smcError):
            guard inventory.ftstKey != nil else { return false }
            switch smcError {
            case .firmwareRejected, .callFailed, .injectedFailure:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func normalize(_ error: Error) -> FanControllerError {
        if let error = error as? FanControllerError { return error }
        if let error = error as? FanHardwareError { return .hardware(error) }
        if let error = error as? SMCError { return .smc(error) }
        if let error = error as? FanRollbackError {
            return .smc(.injectedFailure(error.description))
        }
        return .smc(.injectedFailure(String(describing: error)))
    }

    private func normalizeRollback(_ error: Error) -> FanRollbackError {
        if let error = error as? FanRollbackError { return error }
        if let error = error as? FanControllerError {
            switch error {
            case .smc(let smcError): return .smc(smcError)
            case .hardware(let hardwareError): return .hardware(hardwareError)
            default: return .smc(.injectedFailure(error.description))
            }
        }
        if let error = error as? FanHardwareError { return .hardware(error) }
        if let error = error as? SMCError { return .smc(error) }
        return .smc(.injectedFailure(String(describing: error)))
    }
}
