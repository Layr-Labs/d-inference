import Foundation
import MLXLLM
import MLXLMCommon

/// Read-only provider view of MTP activation and cumulative engine metrics.
/// It deliberately contains no model, prompt, token-id, or controller state.
public struct ProviderMTPStatusSnapshot: Sendable, Equatable {
    public let configured: Bool
    public let active: Bool
    public let verificationMode: String?
    public let fallbackReason: MTPFallbackReason?
    public let assistantSource: SpecDecArtifactSource?
    public let assistantRevision: String?
    public let assistantArtifactBytes: UInt64
    public let assistantResidentBytes: UInt64
    public let selectedDepth: Int
    public let decodeRowBucket: Int
    public let rounds: Int
    public let seedRows: Int
    public let proposedTokens: Int
    public let acceptedDraftTokens: Int
    public let committedEmittedTokens: Int
    public let acceptanceByPosition: [Int]
    public let skippedRows: [String: Int]
    public let controllerFallbacks: [String: Int]

    init(status: MTPActivationStatus, metrics: CBv2MTPMetrics?) {
        let engineActive = metrics?.active == true
        self.configured = status.configured
        self.active = status.active && engineActive
        self.verificationMode = metrics?.verificationMode.rawValue
        self.fallbackReason = status.active && !engineActive ? .engineInactive : status.reason
        self.assistantSource = status.source
        self.assistantRevision = status.revision
        self.assistantArtifactBytes = status.artifactBytes
        self.assistantResidentBytes = status.assistantBytes
        self.selectedDepth = metrics?.selectedDepth ?? 0
        self.decodeRowBucket = metrics?.decodeRowBucket ?? 0
        self.rounds = metrics?.rounds ?? 0
        self.seedRows = metrics?.seedSteps ?? 0
        self.proposedTokens = metrics?.proposedTokens ?? 0
        self.acceptedDraftTokens = metrics?.acceptedTokens ?? 0
        self.committedEmittedTokens = metrics?.emittedTokens ?? 0
        self.acceptanceByPosition = metrics?.perPositionAccepted ?? []
        self.skippedRows = metrics?.skippedRows ?? [:]
        self.controllerFallbacks = metrics?.controllerFallbacks ?? [:]
    }
}

/// Opaque slot-owned assistant lifetime handle. The concrete owner is the
/// loaded `Gemma4AssistantDraftModel`; the adapter is what `EngineV2` calls.
final class ProviderMTPAssistantHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: AnyObject?
    private var storedDrafter: (any CBv2MTPDrafter)?
    private var sourceTargetID: ObjectIdentifier?
    private var servingTarget: (any LanguageModel)?

    var drafter: (any CBv2MTPDrafter)? { lock.withLock { storedDrafter } }

    init(owner: AnyObject, drafter: any CBv2MTPDrafter) {
        self.owner = owner
        self.storedDrafter = drafter
    }

    func bind(sourceTarget: any LanguageModel, servingTarget: any LanguageModel) {
        lock.withLock {
            sourceTargetID = ObjectIdentifier(sourceTarget)
            self.servingTarget = servingTarget
        }
    }

    func recoveryServingTarget(for sourceTarget: any LanguageModel) -> (any LanguageModel)? {
        lock.withLock {
            guard owner != nil, storedDrafter != nil,
                sourceTargetID == ObjectIdentifier(sourceTarget)
            else { return nil }
            return servingTarget
        }
    }

    func release() {
        lock.withLock {
            storedDrafter = nil
            servingTarget = nil
            sourceTargetID = nil
            owner = nil
        }
    }
}

/// One slot's engine and auxiliary ownership. `releaseAssistant()` is explicit
/// so teardown order is observable and cannot depend on struct temporary scope.
final class ProviderEngineBundle: @unchecked Sendable {
    let bridge: EngineV2Bridge
    let mtpArtifact: SpecDecArtifact?
    let mtpStatus: MTPActivationStatus
    let assistantBytes: UInt64

    private let lock = NSLock()
    private var assistant: ProviderMTPAssistantHandle?
    private var pinnedAssistant: (any AnyObject & Sendable)?

    init(
        bridge: EngineV2Bridge,
        assistant: ProviderMTPAssistantHandle?,
        assistantBytes: UInt64,
        mtpArtifact: SpecDecArtifact?,
        mtpStatus: MTPActivationStatus,
        pinnedAssistant: (any AnyObject & Sendable)? = nil
    ) {
        self.bridge = bridge
        self.assistant = assistant
        self.assistantBytes = assistantBytes
        self.mtpArtifact = mtpArtifact
        self.mtpStatus = mtpStatus
        self.pinnedAssistant = pinnedAssistant
    }

    convenience init(targetOnly bridge: EngineV2Bridge) {
        self.init(
            bridge: bridge, assistant: nil, assistantBytes: 0, mtpArtifact: nil,
            mtpStatus: .disabled(.configDisabled, configured: false))
    }

    var hasAssistant: Bool {
        lock.withLock { assistant != nil || pinnedAssistant != nil }
    }

    /// Move the slot-owned assistant into a liveness rebuild. The old bundle
    /// must not release a handle that the replacement engine is reusing.
    func takeAssistantForRecovery() -> ProviderMTPAssistantHandle? {
        lock.withLock {
            let current = assistant
            assistant = nil
            return current
        }
    }

    func releaseAssistant() {
        let handle = lock.withLock { () -> ProviderMTPAssistantHandle? in
            let current = assistant
            assistant = nil
            pinnedAssistant = nil
            return current
        }
        handle?.release()
    }

    deinit {
        releaseAssistant()
    }
}
