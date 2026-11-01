import Foundation
import MLXLMCommon

struct PrefixCacheConstructionStatus: Sendable {
    let state: PrefixCacheStatusState
    let reason: PrefixCacheStatusReason
    /// Typed refusal behind an error status; the heartbeat status carries it
    /// as `detail` (`PrefixCacheModelStatus`).
    var failure: SSDPrefixCacheConstructionFailure? = nil

    static let configDisabled = PrefixCacheConstructionStatus(
        state: .disabled, reason: .configDisabled)
    static let scanPending = PrefixCacheConstructionStatus(
        state: .pending, reason: .scanPending)
}

extension PrefixCacheConstructionStatus {
    /// The status of a refused store, shared by the attention-block and
    /// complete-checkpoint factories: a disk problem is `disk_unavailable`,
    /// layout and weight-hash refusals are their disabled reasons, and every
    /// other refusal is `cache_init_failed`. An error status keeps its typed
    /// cause. `capability` only distinguishes attention-block plan refusals.
    init(refusal failure: SSDPrefixCacheConstructionFailure,
         capability: CBv2PrefixReuseCapability? = nil) {
        switch failure {
        case .missingWeightHash:
            self.init(state: .disabled, reason: .weightHashUnavailable)
        case .unsupportedPlan:
            let dualCursor = capability?.unsupportedReason?.rawValue == "paged_hybrid_requires_dual_cursor"
            self.init(state: .disabled, reason: dualCursor ? .pagedHybridUnsupported : .unsupportedLayout)
        case .layoutUnavailable:
            self.init(state: .disabled, reason: .unsupportedLayout)
        case .unsafePath:
            self.init(state: .error, reason: .diskUnavailable, failure: failure)
        case .keyUnavailable, .ephemeralKeyUnavailable, .blockContractMismatch,
            .epochUnavailable, .promptContractUnavailable, .identityUnavailable,
            .writeBudgetUnavailable, .cacheClosed:
            self.init(state: .error, reason: .cacheInitFailed, failure: failure)
        }
    }
}

final class PrefixCacheConstructionStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PrefixCacheConstructionStatus?

    func record(
        failure: SSDPrefixCacheConstructionFailure,
        capability: CBv2PrefixReuseCapability
    ) {
        lock.withLock {
            value = PrefixCacheConstructionStatus(refusal: failure, capability: capability)
        }
    }

    var snapshot: PrefixCacheConstructionStatus? {
        lock.withLock { value }
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
        guard capability.isSupported else {
            self = .none
            return
        }
        switch capability.strategy?.rawValue {
        case "direct":
            self = .direct
        case "frozen_full_replay":
            self = .frozenFull
        case "tail_replay":
            self = .tailReplay
        default:
            self = .unknown
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
