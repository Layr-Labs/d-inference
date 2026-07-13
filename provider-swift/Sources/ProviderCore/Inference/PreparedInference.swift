// Copyright © 2026 Eigen Labs.
//
// Immutable output of the expensive prepare path.  A caller may construct
// this value only after decrypting the sealed body, rendering its chat
// template, and tokenizing the rendered prompt.  PreparedLeaseManager then
// owns the value until start transfers it to an inference executor or a
// terminal pre-start transition releases it.

import Foundation
import MLXLMCommon
import MLXLMServer

public enum PreparedInferenceError: Error, Equatable, Sendable {
    case emptyRequestDigest
    case modelMismatch(expected: String, actual: String)
    case incompleteDecryption
    case incompleteRendering
    case incompleteTokenization
    case promptTokenCountMismatch(expected: Int, actual: Int)
    case maxOutputTokenCountMismatch(expected: Int, actual: Int)
    case invalidMaxOutputTokens(Int)
    case textRequestCarriesMediaBytes(UInt64)
    case mediaRequestMissingByteCount
}

/// Facts established before a prepared lease can consume serving capacity.
///
/// The counts are deliberately supplied alongside the completed-stage facts
/// and checked against the executable payload.  This prevents a handler from
/// acknowledging a lease using estimates from an encrypted envelope while
/// the engine later executes a differently-sized decoded request.
public struct PreparedInferenceFacts: Sendable, Equatable {
    public let decryptionComplete: Bool
    public let renderingComplete: Bool
    public let tokenizationComplete: Bool
    public let promptTokens: Int
    public let maxOutputTokens: Int
    /// Bytes retained by already-prepared media inputs (decoded pixels,
    /// projected embeddings, or equivalent provider-owned media state).
    /// Text requests must report zero; media requests must report a positive
    /// measured value so admission never silently treats media as free.
    public let mediaBytes: UInt64

    public init(
        decryptionComplete: Bool,
        renderingComplete: Bool,
        tokenizationComplete: Bool,
        promptTokens: Int,
        maxOutputTokens: Int,
        mediaBytes: UInt64 = 0
    ) {
        self.decryptionComplete = decryptionComplete
        self.renderingComplete = renderingComplete
        self.tokenizationComplete = tokenizationComplete
        self.promptTokens = promptTokens
        self.maxOutputTokens = maxOutputTokens
        self.mediaBytes = mediaBytes
    }
}

/// Idempotent release for resources acquired before engine submission, most
/// notably the loaded-model pin.  Both the manager and executor may invoke
/// the backstop on error paths; the underlying release closure runs once.
public actor PreparedInferenceResourceRelease {
    private let operation: @Sendable () async -> Void
    private enum State {
        case pending
        case releasing([CheckedContinuation<Void, Never>])
        case released
    }
    private var state: State = .pending

    public init(_ operation: @escaping @Sendable () async -> Void = {}) {
        self.operation = operation
    }

    public func fire() async {
        switch state {
        case .released:
            return
        case .releasing(var waiters):
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                state = .releasing(waiters)
            }
        case .pending:
            state = .releasing([])
            await operation()
            guard case .releasing(let waiters) = state else {
                preconditionFailure("invalid prepared resource release state")
            }
            state = .released
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func hasFiredForTesting() -> Bool {
        if case .released = state { return true }
        return false
    }
}

/// Completion signal independent of stream consumption.  It lets the lease
/// manager make cancel/abort acknowledgements quiescent without taking a
/// second iterator over (and therefore stealing events from) the caller's
/// generation stream.
public actor PreparedInferenceCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func isFinishedForTesting() -> Bool { finished }
}

public struct PreparedInferenceUsageSnapshot: Sendable, Equatable {
    public let promptTokens: UInt64
    public let finalGeneratedTokens: UInt64

    public init(promptTokens: UInt64, finalGeneratedTokens: UInt64) {
        self.promptTokens = promptTokens
        self.finalGeneratedTokens = finalGeneratedTokens
    }
}

/// Out-of-band actual engine usage. It is updated before terminal error events
/// are yielded, so transport consumers can join engine completion and retain
/// generated-but-undelivered token counts after cancellation.
public actor PreparedInferenceUsageLedger {
    private var promptTokens: UInt64
    private var finalGeneratedTokens: UInt64

    public init(promptTokens: UInt64 = 0, finalGeneratedTokens: UInt64 = 0) {
        self.promptTokens = promptTokens
        self.finalGeneratedTokens = finalGeneratedTokens
    }

    public func record(
        promptTokens: Int? = nil,
        finalGeneratedTokens: Int
    ) {
        if let promptTokens {
            self.promptTokens = max(
                self.promptTokens,
                UInt64(clamping: promptTokens)
            )
        }
        self.finalGeneratedTokens = max(
            self.finalGeneratedTokens,
            UInt64(clamping: finalGeneratedTokens)
        )
    }

    public func snapshot() -> PreparedInferenceUsageSnapshot {
        PreparedInferenceUsageSnapshot(
            promptTokens: promptTokens,
            finalGeneratedTokens: finalGeneratedTokens
        )
    }
}

/// A started inference plus out-of-band terminal and actual-usage signals.
public struct PreparedInferenceExecution: Sendable {
    public let events: AsyncStream<GenerationEvent>
    public let completion: PreparedInferenceCompletion
    public let usageLedger: PreparedInferenceUsageLedger

    public init(
        events: AsyncStream<GenerationEvent>,
        completion: PreparedInferenceCompletion,
        usageLedger: PreparedInferenceUsageLedger = PreparedInferenceUsageLedger()
    ) {
        self.events = events
        self.completion = completion
        self.usageLedger = usageLedger
    }

    public func settledUsage() async -> PreparedInferenceUsageSnapshot {
        await completion.wait()
        return await usageLedger.snapshot()
    }
}

/// Fully decoded, rendered, and tokenized work retained by a prepared lease.
///
/// `@unchecked Sendable` follows `CBv2MultimodalInput`: its embeddings
/// provider is consumed exactly once by engine submission.  Production media
/// preparation hands it evaluated immutable arrays.
public struct PreparedInference: @unchecked Sendable {
    public let identity: AttemptIdentity
    public var requestID: String { identity.requestID.description }
    /// Digest of the encrypted request carried by the prepare control frame.
    /// Used only to distinguish an idempotent duplicate from a conflicting
    /// reuse of the same lease ID.
    public let requestDigest: String
    public let modelID: String
    public let promptTokens: [Int]
    public let request: ChatCompletionRequest
    public let cacheScope: String
    public let logprobsChannel: EngineV2LogprobsChannel?
    public let usageSignal: EngineV2RequestUsageSignal?
    public let multimodal: CBv2MultimodalInput?
    public let mediaKind: EngineV2MediaKind?
    /// Original normalized OpenAI request retained solely for upstream SSE
    /// framing after start authorization. It is never persisted.
    public let streamRequest: OpenAIChatCompletionRequest?
    /// Consumer X25519 key bound into requestDigest. Response frames are sealed
    /// to this key and never to data supplied by a later start command.
    public let responsePublicKey: Data?
    public let tokenizer: TokenizerHandle?
    public let toolCallFormat: ToolCallFormat?
    public let toolSpecs: [[String: any Sendable]]?
    public let facts: PreparedInferenceFacts
    public let resourceRelease: PreparedInferenceResourceRelease

    public init(
        identity: AttemptIdentity,
        requestDigest: String,
        modelID: String,
        promptTokens: [Int],
        request: ChatCompletionRequest,
        cacheScope: String = "",
        logprobsChannel: EngineV2LogprobsChannel? = nil,
        usageSignal: EngineV2RequestUsageSignal? = nil,
        multimodal: CBv2MultimodalInput? = nil,
        mediaKind: EngineV2MediaKind? = nil,
        streamRequest: OpenAIChatCompletionRequest? = nil,
        responsePublicKey: Data? = nil,
        tokenizer: TokenizerHandle? = nil,
        toolCallFormat: ToolCallFormat? = nil,
        toolSpecs: [[String: any Sendable]]? = nil,
        facts: PreparedInferenceFacts,
        resourceRelease: PreparedInferenceResourceRelease = PreparedInferenceResourceRelease()
    ) throws {
        guard !requestDigest.isEmpty else {
            throw PreparedInferenceError.emptyRequestDigest
        }
        guard request.model == modelID else {
            throw PreparedInferenceError.modelMismatch(
                expected: modelID, actual: request.model)
        }
        guard facts.decryptionComplete else {
            throw PreparedInferenceError.incompleteDecryption
        }
        guard facts.renderingComplete else {
            throw PreparedInferenceError.incompleteRendering
        }
        guard facts.tokenizationComplete else {
            throw PreparedInferenceError.incompleteTokenization
        }
        guard facts.promptTokens == promptTokens.count else {
            throw PreparedInferenceError.promptTokenCountMismatch(
                expected: facts.promptTokens, actual: promptTokens.count)
        }
        let requestMaxOutputTokens = request.max_tokens ?? facts.maxOutputTokens
        guard facts.maxOutputTokens >= 0 else {
            throw PreparedInferenceError.invalidMaxOutputTokens(facts.maxOutputTokens)
        }
        guard requestMaxOutputTokens == facts.maxOutputTokens else {
            throw PreparedInferenceError.maxOutputTokenCountMismatch(
                expected: facts.maxOutputTokens, actual: requestMaxOutputTokens)
        }
        if multimodal == nil, facts.mediaBytes != 0 {
            throw PreparedInferenceError.textRequestCarriesMediaBytes(facts.mediaBytes)
        }
        if multimodal != nil, facts.mediaBytes == 0 {
            throw PreparedInferenceError.mediaRequestMissingByteCount
        }

        self.identity = identity
        self.requestDigest = requestDigest
        self.modelID = modelID
        self.promptTokens = promptTokens
        self.request = request
        self.cacheScope = cacheScope
        self.logprobsChannel = logprobsChannel
        self.usageSignal = usageSignal
        self.multimodal = multimodal
        self.mediaKind = mediaKind
        self.streamRequest = streamRequest
        self.responsePublicKey = responsePublicKey
        self.tokenizer = tokenizer
        self.toolCallFormat = toolCallFormat
        self.toolSpecs = toolSpecs
        self.facts = facts
        self.resourceRelease = resourceRelease
    }
}

/// Executor boundary kept independent of ProviderLoop and wire types.  The
/// later handler integration can pass an EngineV2Bridge directly.
public protocol PreparedInferenceExecutor: Sendable {
    func prepareInference(
        _ inference: PreparedInference,
        expiresAt: Date
    ) async throws -> PreparedInferenceAdmission

    /// On success, ownership of `inference.resourceRelease` transfers to the
    /// returned execution and is released at its terminal.
    func startPreparedInference(identity: AttemptIdentity) async throws
        -> PreparedInferenceExecution

    /// Release a prepared-but-unstarted reservation.  Idempotent.
    func abortPreparedInference(identity: AttemptIdentity) async

    /// Cancel started work, or abort it if it has not started.  Idempotent.
    func cancelPreparedInference(identity: AttemptIdentity) async

    /// Escalation after a terminal wait times out. Implementations must
    /// synchronously stop admitting work, forget local reservations, and
    /// finish the out-of-band completion signal without waiting for a wedged
    /// engine stream.
    func forceReleasePreparedInference(identity: AttemptIdentity) async
}

/// Exact facts captured at the executor's successful admission point.
public struct PreparedInferenceAdmission: Sendable, Equatable {
    public let promptTokens: Int
    public let maxOutputTokens: Int
    public let engineQueueDepth: Int
    public let reservedKVBytes: UInt64
    public let reservedMediaBytes: UInt64
    /// False for the pinned CBv2 contract: it has no resumable prefill
    /// boundary, so prepare performs admission only.
    public let prefillCanBegin: Bool
    public let estimatedPrefillMilliseconds: UInt64?

    public init(
        promptTokens: Int,
        maxOutputTokens: Int,
        engineQueueDepth: Int,
        reservedKVBytes: UInt64,
        reservedMediaBytes: UInt64,
        prefillCanBegin: Bool,
        estimatedPrefillMilliseconds: UInt64?
    ) {
        self.promptTokens = promptTokens
        self.maxOutputTokens = maxOutputTokens
        self.engineQueueDepth = engineQueueDepth
        self.reservedKVBytes = reservedKVBytes
        self.reservedMediaBytes = reservedMediaBytes
        self.prefillCanBegin = prefillCanBegin
        self.estimatedPrefillMilliseconds = estimatedPrefillMilliseconds
    }
}
