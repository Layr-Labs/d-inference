import Foundation
import MLXLMCommon

struct PrefixCacheConstructionStatus: Sendable {
    let state: PrefixCacheStatusState
    let reason: PrefixCacheStatusReason

    static let configDisabled = PrefixCacheConstructionStatus(
        state: .disabled, reason: .configDisabled)
    static let scanPending = PrefixCacheConstructionStatus(
        state: .pending, reason: .scanPending)
}

final class PrefixCacheConstructionStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PrefixCacheConstructionStatus?

    func record(
        failure: SSDPrefixCacheConstructionFailure,
        capability: CBv2PrefixReuseCapability
    ) {
        lock.withLock {
            value = Self.status(failure: failure, capability: capability)
        }
    }

    var snapshot: PrefixCacheConstructionStatus? {
        lock.withLock { value }
    }

    private static func status(
        failure: SSDPrefixCacheConstructionFailure,
        capability: CBv2PrefixReuseCapability
    ) -> PrefixCacheConstructionStatus {
        switch failure {
        case .missingWeightHash:
            return PrefixCacheConstructionStatus(
                state: .disabled, reason: .weightHashUnavailable)
        case .unsupportedPlan:
            let reason: PrefixCacheStatusReason =
                capability.unsupportedReason == .pagedHybridRequiresDualCursor
                ? .pagedHybridUnsupported : .unsupportedLayout
            return PrefixCacheConstructionStatus(state: .disabled, reason: reason)
        case .layoutUnavailable:
            return PrefixCacheConstructionStatus(
                state: .disabled, reason: .unsupportedLayout)
        case .unsafePath:
            return PrefixCacheConstructionStatus(
                state: .error, reason: .diskUnavailable)
        case .keyUnavailable, .ephemeralKeyUnavailable, .blockContractMismatch,
            .epochUnavailable, .promptContractUnavailable:
            return PrefixCacheConstructionStatus(
                state: .error, reason: .cacheInitFailed)
        }
    }
}

extension PrefixCacheStatusBackend {
    init(_ backend: EngineV2KVBackendKind) {
        switch backend {
        case .contiguous:
            self = .contiguous
        case .paged:
            self = .paged
        }
    }
}

extension PrefixCacheReplayStrategy {
    init(_ capability: CBv2PrefixReuseCapability?) {
        guard let capability else {
            self = .unknown
            return
        }
        // isSupported implies a non-nil strategy; the exhaustive switch makes
        // any future engine strategy a compile error instead of a silent
        // .unknown, forcing a conscious wire-vocabulary mapping.
        guard capability.isSupported, let strategy = capability.strategy else {
            self = .none
            return
        }
        switch strategy {
        case .direct:
            self = .direct
        case .frozenFullReplay:
            self = .frozenFull
        case .tailReplay:
            self = .tailReplay
        }
    }
}

extension PrefixCacheModelStatus {
    var isConcreteReady: Bool {
        guard state == .ready, reason == .ready,
            backend == .contiguous || backend == .paged
        else { return false }
        switch replayStrategy {
        case .direct, .frozenFull, .tailReplay:
            return true
        case .none, .unknown:
            return false
        }
    }

    func withoutRuntimeIdentity() -> PrefixCacheModelStatus {
        guard state == .ready || state == .pending else { return self }
        return PrefixCacheModelStatus(
            modelId: modelId,
            backend: backend,
            replayStrategy: replayStrategy,
            state: .disabled,
            reason: .runtimeIdentityUnavailable)
    }
}
