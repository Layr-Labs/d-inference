// Copyright © 2026 Eigen Labs.
//
// Registry value types consumed by ``MultiModelBatchSchedulerEngine``.
//
// These live in a dedicated file so the main engine file only carries
// the `MLXServerEngine` conformance methods + the closure-based
// constructors. The types here are pure data + the
// ``OneShotRelease`` actor and opt-in native host-task ownership.
//
// v0.7.5 ONE-ENGINE shape: `engineV2Bridge` is the serving engine for
// EVERY production entry — ProviderLoop slots AND the standalone
// `darkbloom start --local` server's slots. A request that reaches an
// entry with NO bridge is a hard internal error (fail-loud insurance).
// `visionGate` owns the media path's memory reservations (media-decode
// RAM + generation KV against the shared budget).

import Foundation
import MLXLMCommon
import MLXVLM

public extension MultiModelBatchSchedulerEngine {

    /// Snapshot entry for a single loaded model. Returned by the
    /// `registryProvider` closure each time the engine needs to route
    /// a request.
    struct ModelRegistryEntry: Sendable {
        /// Tokenizer wrapper for token-utility endpoints
        /// (`/tokenize`, `/detokenize`, `/apply-template`).
        public let tokenizer: TokenizerHandle
        /// The `model_type` from config.json (e.g. `"gpt_oss"`, `"gemma4"`).
        /// Used to auto-select reasoning and tool call parsers.
        public let modelType: String?
        /// The loaded model container. Present for VLM models so multimodal
        /// requests can run the non-batched `prepare`/`generate` vision path.
        public let container: ModelContainer?
        public let diffusionContainer: DiffusionGemmaContainer?
        /// Whether this model is a vision-language model (config has a
        /// `vision_config`). When true, requests that carry image/video
        /// content are routed to the media path.
        public let isVLM: Bool
        /// ContinuousBatchingV2 bridge — the serving engine. Non-nil for
        /// EVERY production entry (ProviderLoop and standalone slots).
        public let engineV2Bridge: EngineV2Bridge?
        /// Memory gate for the legacy VLM media path (media-decode RAM +
        /// generation KV against the shared budget). nil ⇒ gating disabled
        /// (standalone / unit tests without a shared ledger).
        public let visionGate: VisionMemoryGate?

        public init(
            tokenizer: TokenizerHandle,
            modelType: String? = nil,
            container: ModelContainer? = nil, diffusionContainer: DiffusionGemmaContainer? = nil, isVLM: Bool = false,
            engineV2Bridge: EngineV2Bridge? = nil,
            visionGate: VisionMemoryGate? = nil
        ) {
            self.tokenizer = tokenizer
            self.modelType = modelType
            self.container = container
            self.diffusionContainer = diffusionContainer
            self.isVLM = isVLM
            self.engineV2Bridge = engineV2Bridge
            self.visionGate = visionGate
        }
    }

    /// Tokenizer plus the loaded model type used by token utility endpoints.
    /// `/apply-template` needs both: model-family normalization must not depend
    /// on a registry ID containing a recognizable family name.
    struct TokenizerResolution: Sendable {
        public let tokenizer: TokenizerHandle
        public let modelType: String?

        public init(tokenizer: TokenizerHandle, modelType: String?) {
            self.tokenizer = tokenizer
            self.modelType = modelType
        }
    }

    /// Snapshot type returned by `registryProvider`. Keyed by model id
    /// exactly as it appears in `OpenAIChatCompletionRequest.model`.
    typealias Registry = [String: ModelRegistryEntry]

    /// Result of `acquire(modelId:)`. Carries the engine/tokenizer state
    /// for the just-acquired model plus a `releaseToken` actor that must be
    /// fired exactly once when the request is finished (whether by normal
    /// completion, cancellation, or error). Used by the atomic
    /// `ensureLoaded + reserve` paths (`StandaloneServer`,
    /// `ProviderLoop+LocalEndpoint`).
    struct AcquiredModel: Sendable {

        public let tokenizer: TokenizerHandle
        public let releaseToken: OneShotRelease
        /// The exact token-owned native lease, not a second independent marker.
        public var nativeConsumerLease: NativeLocalConsumerLease? { releaseToken.nativeConsumerLease }
        /// The `model_type` from config.json.
        public let modelType: String?
        /// The loaded model container (present for VLM models — see
        /// ``ModelRegistryEntry/container``).
        public let container: ModelContainer?
        public let diffusionContainer: DiffusionGemmaContainer?
        /// Whether this model is a vision-language model.
        public let isVLM: Bool
        /// ContinuousBatchingV2 bridge — the serving engine (see
        /// ``ModelRegistryEntry/engineV2Bridge``).
        public let engineV2Bridge: EngineV2Bridge?
        /// Memory gate for the legacy VLM media path (see
        /// ``ModelRegistryEntry/visionGate``).
        public let visionGate: VisionMemoryGate?

        public init(
                        tokenizer: TokenizerHandle,
            releaseToken: OneShotRelease,
            modelType: String? = nil,
            container: ModelContainer? = nil,
            diffusionContainer: DiffusionGemmaContainer? = nil,
            isVLM: Bool = false,
            engineV2Bridge: EngineV2Bridge? = nil,
            visionGate: VisionMemoryGate? = nil
        ) {
            self.tokenizer = tokenizer
            self.releaseToken = releaseToken
            self.modelType = modelType
            self.container = container
            self.diffusionContainer = diffusionContainer
            self.isVLM = isVLM
            self.engineV2Bridge = engineV2Bridge
            self.visionGate = visionGate
        }
    }
}

/// Ensures the release closure runs exactly once even though the
/// streaming task body and the `onTermination` handler can both fire
/// on a cancellation race.
public actor OneShotRelease {
    private let release: @Sendable (String) async -> Void
    private let modelId: String
    private var fired = false
    public nonisolated let nativeConsumerLease: NativeLocalConsumerLease?
    nonisolated let nativeBindingAccepted: Bool

    public init(release: @escaping @Sendable (String) async -> Void, modelId: String,
                nativeConsumerLease: NativeLocalConsumerLease? = nil) {
        self.release = release
        self.modelId = modelId
        self.nativeConsumerLease = nativeConsumerLease
        nativeBindingAccepted = nativeConsumerLease?.bind(release: release, modelId: modelId) ?? true
    }

    public func fire() async {
        guard !fired else { return }
        fired = true
        if let nativeConsumerLease {
            guard nativeBindingAccepted else { return } // cannot act through another token's binding
            nativeConsumerLease.requestRelease()
            return // Never self-await the forwarding/preparation task calling fire.
        }
        await release(modelId)
    }
}

public enum NativeLocalConsumerOwnershipError: Error, Equatable, Sendable {
    case closed, invalidBinding, preparationAlreadyStarted, forwardingAlreadyStarted
}

private enum NativeLocalConsumerTaskContext {
    @TaskLocal static var leaseID: UUID?
}

/// Host-task ownership only. This is NOT an SDK completion receipt, a load/KV
/// refund or physical-free proof. A slot owner installs/retains it before an
/// acquisition can escape; actual native shutdown must precede dependent joins.
public final class NativeLocalConsumerLease: @unchecked Sendable {
    public enum Phase: String, Sendable { case awaitingBinding, active, closing, releasing, completed, abandoned }
    public struct Snapshot: Sendable {
        public let id: UUID
        public let revision: UInt64
        public let phase: Phase
        public let hasOutstandingHandoff: Bool
    }
    public enum ColdAbandonment: Equatable, Sendable {
        /// No callback was ever bound. Caller performs the EXISTING no-work
        /// reservation unwind and retains its basis through that unwind.
        case unbound
        /// Close/release requested; the bound Scheduler handoff must still
        /// actually adopt or discard its payload before callback completion.
        case boundReleaseRequested
        /// Strictly a repeat of prior UNBOUND abandonment.
        case alreadyAbandoned
    }
    private protocol OwnedTask: Sendable {
        func cancel()
        func join() async
    }
    private struct TaskOwner<Value: Sendable, Failure: Error>: OwnedTask {
        let task: Task<Value, Failure>
        let cancelOnClose: Bool
        init(task: Task<Value, Failure>, cancelOnClose: Bool = true) {
            self.task = task; self.cancelOnClose = cancelOnClose
        }
        func cancel() { if cancelOnClose { task.cancel() } }
        func join() async { _ = await task.result }
    }
    public let id = UUID()
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var closed = false
    private var bound = false
    private var preparationRegistered = false
    private var coldDisposed = false
    private var unboundAbandoned = false
    private var streamRegistered = false
    private var terminationPending = false
    private var cancellationRegistered = false
    private var forwardingID: UUID?
    private var drainsForwardingTerminal = false
    private var cancellation: (@Sendable () async -> Void)?
    private var tasks: [UUID: any OwnedTask] = [:]
    private var releaseAction: (@Sendable () async -> Void)?
    private var mediaHostCompletion: (id: UUID, action: @Sendable () -> Void)?
    private var releaseRequested = false
    private var releasing = false
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Binding AND preparation handoff are armed from initialization, including
    /// while an owner's async lease factory has not yet returned to Scheduler.
    public init() {}
    private func changed() { revision &+= 1 }

    fileprivate func bind(release: @escaping @Sendable (String) async -> Void, modelId: String) -> Bool {
        lock.withLock {
            guard !bound, !unboundAbandoned, !completed else { return false }
            bound = true
            releaseAction = { await release(modelId) }
            changed()
            return true
        }
    }
    public func snapshot() -> Snapshot {
        lock.withLock {
            let phase: Phase = unboundAbandoned ? .abandoned : completed ? .completed : releasing ? .releasing
                : closed || releaseRequested ? .closing : bound ? .active : .awaitingBinding
            return .init(id: id, revision: revision, phase: phase,
                hasOutstandingHandoff: !bound && !unboundAbandoned
                    || (!preparationRegistered && !coldDisposed) || terminationPending)
        }
    }

    /// One native-media budget owner, installed during the existing registered
    /// preparation. No new task/lease/receipt. Runs after actual Task joins and
    /// the original release callback, outside locks, before lease completion.
    func installMediaHostCompletion(id: UUID, _ action: @escaping @Sendable () -> Void) throws {
        guard NativeLocalConsumerTaskContext.leaseID == self.id else {
            throw NativeLocalConsumerOwnershipError.invalidBinding
        }
        try lock.withLock {
            guard bound, preparationRegistered, !coldDisposed, !unboundAbandoned,
                  !releasing, !completed, mediaHostCompletion == nil else {
                throw NativeLocalConsumerOwnershipError.invalidBinding
            }
            mediaHostCompletion = (id,action)
            changed()
        }
    }

    @discardableResult
    public func abandonUnstartedHandoff() throws -> ColdAbandonment {
        let result: (ColdAbandonment, [CheckedContinuation<Void, Never>]) = try lock.withLock {
            if coldDisposed {
                return (unboundAbandoned ? .alreadyAbandoned : .boundReleaseRequested, [])
            }
            guard !preparationRegistered, !streamRegistered, tasks.isEmpty else {
                throw NativeLocalConsumerOwnershipError.preparationAlreadyStarted
            }
            closed = true; releaseRequested = true; changed()
            if !bound {
                coldDisposed = true; unboundAbandoned = true
                let parked = waiters; waiters = []
                return (.unbound, parked)
            }
            return (.boundReleaseRequested, [])
        }
        for waiter in result.1 { waiter.resume() }
        scheduleReleaseIfReady()
        return result.0
    }

    /// Scheduler-only evidence: its transferred acquisition has actually been
    /// discarded, not merely cancelled by the owner while still in transit.
    func discardUnstartedPreparation() throws {
        try lock.withLock {
            guard bound, !preparationRegistered, !streamRegistered, tasks.isEmpty else {
                throw NativeLocalConsumerOwnershipError.preparationAlreadyStarted
            }
            closed = true; coldDisposed = true; releaseRequested = true; changed()
        }
        scheduleReleaseIfReady()
    }

    /// Close is not completion. Armed unstarted/binding/termination handoffs
    /// remain outstanding until real adoption/typed cold disposal resolves them.
    public func closeAndCancel() {
        let current = lock.withLock { () -> [any OwnedTask] in
            closed = true; releaseRequested = true; changed()
            return Array(tasks.values)
        }
        for task in current { task.cancel() } // cancellation handlers may reenter
        cancelStream(terminating: false)
        scheduleReleaseIfReady()
    }

    /// External control task only. Must not run from a task/release callback
    /// owned by this lease, or before driving an SDK drain it depends upon.
    public func joinFromOutside() async {
        precondition(NativeLocalConsumerTaskContext.leaseID != id, "native local consumer cannot self-join")
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if completed || unboundAbandoned { return true }
                waiters.append(continuation); return false
            }
            if ready { continuation.resume() }
        }
    }
    fileprivate func requestRelease() {
        lock.withLock { closed = true; releaseRequested = true; changed() }
        scheduleReleaseIfReady()
    }

    /// The body MUST take/dispose the transferred payload and honor cancellation
    /// before native work. It runs even if already cancelled, so no raw acquired
    /// payload is left parked in an unstarted closure after a registered task.
    func startPreparation<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Task<Value, Error> {
        let gate = NativeLocalTaskStartGate(), taskID = UUID()
        let task: Task<Value, Error> = try lock.withLock {
            guard bound, !unboundAbandoned, !coldDisposed else { throw NativeLocalConsumerOwnershipError.invalidBinding }
            guard !closed else { throw NativeLocalConsumerOwnershipError.closed }
            guard !preparationRegistered else { throw NativeLocalConsumerOwnershipError.preparationAlreadyStarted }
            preparationRegistered = true
            let task = Task {
                await gate.wait()
                return try await NativeLocalConsumerTaskContext.$leaseID.withValue(self.id) { try await operation() }
            }
            tasks[taskID] = TaskOwner(task: task); changed()
            return task
        }
        observe(TaskOwner(task: task), id: taskID)
        gate.open()
        return task
    }

    struct ForwardingHandoff: Sendable {
        let task: Task<Void, Never>
        let gate: NativeLocalTaskStartGate
        let lease: NativeLocalConsumerLease
        func activate() { gate.open() }
        func cancel() { lease.cancelStream(terminating: false) }
        func terminate() { lease.cancelStream(terminating: true) }
    }
    /// A terminal-draining forwarder stays registered through real upstream
    /// closure; cancellation still invokes the same tracked bridge callback.
    /// The default retains every existing caller's direct-task cancellation.
    func makeForwardingHandoff(cancelForwardingTask: Bool = true,
                               cancel: @escaping @Sendable () async -> Void,
                               operation: @escaping @Sendable () async -> Void) throws -> ForwardingHandoff {
        let gate = NativeLocalTaskStartGate(), taskID = UUID()
        let task: Task<Void, Never> = try lock.withLock {
            let ownedClosedDrain = !cancelForwardingTask
                && NativeLocalConsumerTaskContext.leaseID == id
            guard bound, preparationRegistered, !coldDisposed, !completed, !releasing,
                  !closed || ownedClosedDrain else {
                throw NativeLocalConsumerOwnershipError.closed
            }
            guard !streamRegistered else { throw NativeLocalConsumerOwnershipError.forwardingAlreadyStarted }
            streamRegistered = true; terminationPending = true; cancellation = cancel; forwardingID = taskID
            drainsForwardingTerminal = !cancelForwardingTask
            let task = Task {
                await gate.wait()
                await NativeLocalConsumerTaskContext.$leaseID.withValue(self.id) { await operation() }
            }
            tasks[taskID] = TaskOwner(task: task, cancelOnClose: cancelForwardingTask); changed()
            return task
        }
        observe(TaskOwner(task: task, cancelOnClose: cancelForwardingTask), id: taskID)
        // Close may have won before stream registration. Coalesce the actual
        // bridge cancellation while the tracked drainer still waits on its gate.
        if lock.withLock({ closed }) { cancelStream(terminating: false) }
        // Caller arms termination/disconnect callbacks before opening this gate.
        return .init(task: task, gate: gate, lease: self)
    }

    private func cancelStream(terminating: Bool) {
        let result: ((any OwnedTask)?, (UUID, Task<Void, Never>, NativeLocalTaskStartGate)?) = lock.withLock {
            guard streamRegistered, !completed, !unboundAbandoned else { return (nil, nil) }
            if drainsForwardingTerminal { closed = true; releaseRequested = true }
            let forward = forwardingID.flatMap { tasks[$0] }
            var made: (UUID, Task<Void, Never>, NativeLocalTaskStartGate)?
            if !cancellationRegistered, let cancellation {
                let taskID = UUID(), gate = NativeLocalTaskStartGate()
                let task = Task {
                    await gate.wait()
                    await NativeLocalConsumerTaskContext.$leaseID.withValue(self.id) { await cancellation() }
                }
                cancellationRegistered = true
                tasks[taskID] = TaskOwner(task: task)
                made = (taskID, task, gate)
            }
            // The coalesced cleanup handle is installed BEFORE the armed
            // termination promise can disappear. No empty-map completion gap.
            if terminating { terminationPending = false }
            changed()
            return (forward, made)
        }
        result.0?.cancel()
        if let made = result.1 {
            observe(TaskOwner(task: made.1), id: made.0)
            made.2.open()
        }
        scheduleReleaseIfReady()
    }
    private func observe(_ task: any OwnedTask, id taskID: UUID) {
        Task.detached { [self] in
            await task.join() // actual Task.result, never a count/timeout proxy
            lock.withLock { tasks.removeValue(forKey: taskID); changed() }
            scheduleReleaseIfReady()
        }
    }
    private func scheduleReleaseIfReady() {
        let action: (@Sendable () async -> Void)? = lock.withLock {
            guard releaseRequested, bound, preparationRegistered || coldDisposed,
                  !terminationPending, tasks.isEmpty, !releasing, !completed,
                  !unboundAbandoned, let action = releaseAction else { return nil }
            releasing = true; releaseAction = nil; cancellation = nil; changed()
            return action
        }
        guard let action else { return }
        // This coordinator is not a consumer task and joins no task it owns.
        // All model-using task handles have already returned before the logical
        // release callback runs. Its remaining tail is metadata-only.
        Task.detached { [self] in
            await NativeLocalConsumerTaskContext.$leaseID.withValue(id) { await action() }
            let mediaCompletion = lock.withLock {
                let current = mediaHostCompletion
                mediaHostCompletion = nil
                return current?.action
            }
            mediaCompletion?()
            let parked = lock.withLock {
                completed = true; releasing = false; changed()
                let parked = waiters; waiters = []; return parked
            }
            for waiter in parked { waiter.resume() }
        }
    }
}

/// Cancellation-insensitive start handshake. A cancelled task still waits for
/// handle installation and payload ownership transfer before executing cleanup.
final class NativeLocalTaskStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if opened { return true }
                waiter = continuation; return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let parked = lock.withLock {
            opened = true; let parked = waiter; waiter = nil; return parked
        }
        parked?.resume()
    }
}

/// Stores only an existing Sendable acquisition, never a raw model/array in a
/// new unchecked transfer box. The Scheduler's outer async frame retains an
/// EMPTY box once the actual owned preparation task takes its payload.
final class NativeLocalAcquisitionPayload: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MultiModelBatchSchedulerEngine.AcquiredModel?
    init(_ value: consuming MultiModelBatchSchedulerEngine.AcquiredModel) { self.value = value }
    func take() -> MultiModelBatchSchedulerEngine.AcquiredModel? {
        lock.withLock { let current = value; value = nil; return current }
    }
    func discard() { lock.withLock { value = nil } }
}

final class NativeLocalDisconnectRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LocalRequestCancellationScope.Registration?
    func set(_ value: LocalRequestCancellationScope.Registration?) { lock.withLock { self.value = value } }
    func remove() {
        let current = lock.withLock { let current = value; value = nil; return current }
        current?.remove()
    }
}
