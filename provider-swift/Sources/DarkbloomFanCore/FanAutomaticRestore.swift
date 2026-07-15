import Foundation

public struct FanAutomaticRestoreOutcome: Equatable, Sendable {
    public let unresolvedFanIndices: [Int]
    public let ownsFtst: Bool
    public let failures: [FanRollbackFailure]

    public init(
        unresolvedFanIndices: [Int],
        ownsFtst: Bool,
        failures: [FanRollbackFailure]
    ) {
        self.unresolvedFanIndices = Array(Set(unresolvedFanIndices)).sorted()
        self.ownsFtst = ownsFtst
        self.failures = failures
    }
}

/// Restores every tracked fan and the optional global force-test gate with a
/// shared, bounded retry budget. Each round attempts fan Auto first and Ftst
/// release second. A later round then re-verifies fans after macOS has had an
/// opportunity to reclaim them.
public enum FanAutomaticRestore {
    public static func run(
        backend: any SMCBackend,
        fans: [FanCapability],
        ftstKey: SMCKey?,
        ownsFtst: Bool,
        timing: FanControlTiming = .production
    ) -> FanAutomaticRestoreOutcome {
        var unresolvedFans: [Int: FanCapability] = [:]
        var fanErrors: [Int: FanRollbackError] = [:]
        var terminalFans = Set<Int>()
        for fan in fans {
            unresolvedFans[fan.index] = fan
        }

        var unresolvedFtst = ownsFtst
        var ftstError: FanRollbackError?
        var terminalFtst = false

        for attempt in 0..<timing.automaticRestoreAttempts {
            for fan in unresolvedFans.values.sorted(by: { $0.index < $1.index })
                where !terminalFans.contains(fan.index)
            {
                do {
                    try backend.write(
                        fan.modeKey,
                        bytes: [FanMode.automatic.rawValue]
                    )
                    let raw = try backend.read(fan.modeKey).uint8()
                    guard FanMode(rawValue: raw).isAutomatic else {
                        throw FanRollbackError.modeNotAutomatic(rawValue: raw)
                    }
                    unresolvedFans.removeValue(forKey: fan.index)
                    fanErrors.removeValue(forKey: fan.index)
                    clearTargetBestEffort(backend: backend, fan: fan)
                } catch {
                    let normalized = normalize(error)
                    fanErrors[fan.index] = normalized
                    if !isRetryable(normalized) {
                        terminalFans.insert(fan.index)
                    }
                }
            }

            if unresolvedFtst, !terminalFtst {
                if let ftstKey {
                    do {
                        try backend.write(ftstKey, bytes: [0])
                        let raw = try backend.read(ftstKey).uint8()
                        guard raw == 0 else {
                            throw FanRollbackError.ftstStillSet(rawValue: raw)
                        }
                        unresolvedFtst = false
                        ftstError = nil
                    } catch {
                        let normalized = normalize(error)
                        ftstError = normalized
                        terminalFtst = !isRetryable(normalized)
                    }
                } else {
                    ftstError = .smc(.keyNotFound("Ftst"))
                    terminalFtst = true
                }
            }

            if unresolvedFans.isEmpty, !unresolvedFtst {
                break
            }
            if terminalFans.count == unresolvedFans.count,
               !unresolvedFtst || terminalFtst
            {
                break
            }
            if attempt + 1 < timing.automaticRestoreAttempts {
                timing.sleep(timing.retryDelaySeconds)
            }
        }

        var failures = unresolvedFans.keys.sorted().map { index in
            FanRollbackFailure(
                fanIndex: index,
                step: .restoreMode,
                error: fanErrors[index] ?? .modeNotAutomatic(rawValue: 1)
            )
        }
        if unresolvedFtst {
            failures.append(FanRollbackFailure(
                fanIndex: nil,
                step: .clearFtst,
                error: ftstError ?? .ftstStillSet(rawValue: 1)
            ))
        }
        return FanAutomaticRestoreOutcome(
            unresolvedFanIndices: Array(unresolvedFans.keys),
            ownsFtst: unresolvedFtst,
            failures: failures
        )
    }

    private static func clearTargetBestEffort(
        backend: any SMCBackend,
        fan: FanCapability
    ) {
        guard let zero = try? SMCValue.float32Bytes(0, key: fan.targetKey) else {
            return
        }
        try? backend.write(fan.targetKey, bytes: zero)
    }

    private static func normalize(_ error: Error) -> FanRollbackError {
        if let error = error as? FanRollbackError { return error }
        if let error = error as? FanHardwareError { return .hardware(error) }
        if let error = error as? SMCError { return .smc(error) }
        if let error = error as? FanControllerError {
            switch error {
            case .hardware(let hardware): return .hardware(hardware)
            case .smc(let smc): return .smc(smc)
            default: return .smc(.injectedFailure(error.description))
            }
        }
        return .smc(.injectedFailure(String(describing: error)))
    }

    private static func isRetryable(_ error: FanRollbackError) -> Bool {
        switch error {
        case .modeNotAutomatic, .ftstStillSet:
            return true
        case .smc(let error):
            switch error {
            case .callFailed, .firmwareRejected, .injectedFailure:
                return true
            default:
                return false
            }
        case .hardware, .persistence:
            return false
        }
    }
}
