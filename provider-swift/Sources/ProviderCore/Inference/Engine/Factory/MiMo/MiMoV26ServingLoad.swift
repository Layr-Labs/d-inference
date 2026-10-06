import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation
import Darwin

enum MiMoV26ServingLoadError: Error, Equatable {
    case metadata, changedDescriptor, invalidLifecycle, managedLoadRequired, unsupportedBackend
    case externalAssistantUnsupported, arithmeticOverflow, nativeOwnerMismatch
}

/// Metadata facade over a strongly registered host transaction. The private
/// non-Sendable SDK session is removed before its one-shot consuming transfer.
/// Transaction ownership is raw ModelContainer only, never this facade's
/// self-containing ProviderModelContainer enum. Provenance is not payload auth.
final class MiMoV26ServingLoad: @unchecked Sendable {
    /// Transfers the non-Sendable load session once to the serialized native
    /// construction lane. SDK package-private helpers are not provider API.
    final class AudioSessionTransfer: @unchecked Sendable {
        private let lock = NSLock()
        private var session: MiMoV26AudioSidecarLoadSession?
        init(_ session: consuming MiMoV26AudioSidecarLoadSession) {
            self.session = consume session
        }
        func consume() throws -> MiMoV26AudioSidecarLoadSession {
            try lock.withLock {
                guard let session else { throw MiMoV26ServingLoadError.invalidLifecycle }
                self.session = nil
                return session
            }
        }
    }

    struct DecodedMediaPolicy: Sendable {
        let limits: MiMoV26MultimodalLimits
        let maximumReservationBytes: UInt64
        let additionalSystemReserveBytes: UInt64
        init(limits: MiMoV26MultimodalLimits, maximumReservationBytes: UInt64,
             additionalSystemReserveBytes: UInt64) throws {
            guard maximumReservationBytes > 0, additionalSystemReserveBytes > 0 else {
                throw MiMoV26MultimodalError.reservationRejected
            }
            self.limits = limits; self.maximumReservationBytes = maximumReservationBytes
            self.additionalSystemReserveBytes = additionalSystemReserveBytes
        }
    }
    struct DecodedAudioPolicy: Sendable {
        let media: DecodedMediaPolicy
        let maximumSidecarReservationBytes, additionalSystemReserveBytes: UInt64
        init(media: DecodedMediaPolicy, maximumSidecarReservationBytes: UInt64,
             additionalSystemReserveBytes: UInt64) throws {
            guard maximumSidecarReservationBytes > 0, additionalSystemReserveBytes > 0 else {
                throw MiMoV26AudioSidecarError.insufficientReservation
            }
            self.media = media
            self.maximumSidecarReservationBytes = maximumSidecarReservationBytes
            self.additionalSystemReserveBytes = additionalSystemReserveBytes
        }
    }
    let decodedMediaPolicy: DecodedMediaPolicy?
    let decodedAudioPolicy: DecodedAudioPolicy?
    let audioLoadRequest: MiMoV26AudioSidecarLoadRequest?
    struct Metadata: Equatable, Sendable {
        let object: MiMoV26FilesystemObjectState
        let bytes: Data
    }
    struct Manifest: Decodable {
        let source_repository, source_revision, source_config_sha256: String
        let experts, dense: String
        let output_tensor_count, output_weight_bytes: Int
        let modality_tensor_counts: [String: Int]
        let mtp_embedded: Embedded
        struct Embedded: Decodable {
            let architecture, storage, file: String
            let num_layers: Int
        }
    }
    private var session: MiMoV26SerialLoadSession?
    private var audioSession: MiMoV26AudioSidecarLoadSession?
    private let estimatedLoadBytes: UInt64
    let request: MiMoV26SerialLoadRequest
    let plan: MiMoV26FilesystemLoadPlan
    private let manifest: Metadata
    private let manifestFile: String
    private let lock = NSLock()
    private var transactionStorage: MiMoV26NativeLoadTransaction?
    private var loadStarted = false
    private var cancelled = false
    var transaction: MiMoV26NativeLoadTransaction? { lock.withLock { transactionStorage } }
    var estimatedWeightsGb: Double { Double(estimatedLoadBytes) / 1_073_741_824 }
    /// Intent eligibility from the already validated closed native inventory.
    /// Actual assistant creation still requires genuine loaded weights/owners.
    var hasEmbeddedMTP: Bool {
        plan.bundlePlan.configuration.numNextnPredictLayers > 0
            && plan.bundlePlan.tensorBytes(for: .mtp) > 0
    }

    static func inspect(directory: URL, decodedMediaPolicy: DecodedMediaPolicy? = nil,
                        decodedAudioPolicy: DecodedAudioPolicy? = nil) throws -> MiMoV26ServingLoad? {
        let config = try readMetadata(directory.appendingPathComponent("config.json"), limit: 1 << 20)
        struct Declaration: Decodable { let model_type: String }
        guard try JSONDecoder().decode(Declaration.self, from: config.bytes).model_type == "mimo_v2" else { return nil }
        return try MiMoV26ServingLoad(directory: directory, config: config,
            decodedMediaPolicy: decodedMediaPolicy, decodedAudioPolicy: decodedAudioPolicy)
    }

    private init(directory: URL, config: Metadata, decodedMediaPolicy: DecodedMediaPolicy?,
                 decodedAudioPolicy: DecodedAudioPolicy?) throws {
        guard decodedMediaPolicy == nil || decodedAudioPolicy == nil else {
            throw MiMoV26ServingLoadError.metadata // explicit audio policy already includes visual limits
        }
        self.decodedAudioPolicy = decodedAudioPolicy
        self.decodedMediaPolicy = decodedAudioPolicy?.media ?? decodedMediaPolicy
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let index = try Self.readMetadata(root.appendingPathComponent("model.safetensors.index.json"), limit: 4 << 20)
        let manifests = ["conversion_manifest.json", "artifact-provenance.json"].filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
        guard manifests.count == 1 else { throw MiMoV26ServingLoadError.metadata }
        manifestFile = manifests[0]
        manifest = try Self.readMetadata(root.appendingPathComponent(manifestFile), limit: 1 << 20)
        let artifact = try MiMoV26ServingArtifact.parse(manifest.bytes, file: manifestFile,
            configuration: config.bytes, index: index.bytes)
        let configHash = Self.hash(config.bytes), indexHash = Self.hash(index.bytes)
        plan = try MiMoV26FilesystemWeights.preflight(root: root, provenance: artifact.provenance,
            limits: .init(maximumShardBytes: 64 << 30, maximumTotalFileBytes: 512 << 30),
            expectations: .init(configurationSHA256: configHash, indexSHA256: indexHash),
            isCancelled: { Task.isCancelled })
        guard plan.configurationObject == config.object, plan.indexObject == index.object
        else { throw MiMoV26ServingLoadError.metadata }
        try artifact.validate(plan.bundlePlan)
        let session = try MiMoV26SerialLoadSession(plan: plan)
        request = session.request
        self.session = session
        if decodedAudioPolicy != nil {
            let audio = try MiMoV26AudioSidecarLoadSession(root: root,
                mainConfiguration: plan.bundlePlan.configuration, mainConfigurationSHA256: configHash,
                isCancelled: { Task.isCancelled })
            audioLoadRequest = audio.request; audioSession = audio
            let total = request.requiredLoadBytes.addingReportingOverflow(audio.request.requiredLoadBytes)
            guard !total.overflow else { throw MiMoV26ServingLoadError.arithmeticOverflow }
            estimatedLoadBytes = total.partialValue
        } else { audioLoadRequest = nil; estimatedLoadBytes = request.requiredLoadBytes }
        try validateDescriptor()
    }

    func validateDescriptor() throws {
        try Task.checkCancellation()
        guard try Self.readMetadata(plan.canonicalRoot.appendingPathComponent(manifestFile), limit: 1 << 20) == manifest else {
            throw MiMoV26ServingLoadError.changedDescriptor
        }
        try MiMoV26FilesystemWeights.validateCurrentObjects(plan: plan, isCancelled: { Task.isCancelled })
        // Before transfer only. Once consumed, the real installed owner is
        // validated through the serialized model lane, never a raw session alias.
        try lock.withLock { try audioSession?.validateSource() }
    }

    /// Root creates one lifecycle for its real ProviderLoop/Standalone/session
    /// owner, not an implicit fresh authorization token for each model call.
    func claim(budget: GlobalKVCacheBudget, lifecycle: MiMoV26NativeLifecycle,
               registry: MiMoV26NativeLoadRegistry = .shared) throws {
        try validateDescriptor()
        let installed = try lock.withLock {
            guard transactionStorage == nil, !loadStarted, !cancelled else {
                throw MiMoV26ServingLoadError.invalidLifecycle
            }
            let transaction = try registry.install(request: request, budget: budget, lifecycle: lifecycle)
            transactionStorage = transaction // before even the real permit claim
            return transaction
        }
        do {
            try installed.claimPermit()
            if let audioLoadRequest, let decodedAudioPolicy {
                try installed.claimAudioSidecar(request: audioLoadRequest, policy: decodedAudioPolicy)
            }
        }
        catch { installed.revoke(); throw error }
    }

    private func requiredTransaction() throws -> MiMoV26NativeLoadTransaction {
        try lock.withLock {
            guard let transactionStorage else { throw MiMoV26ServingLoadError.managedLoadRequired }
            return transactionStorage
        }
    }

    func recheck() throws {
        try validateDescriptor()
        try requiredTransaction().recheckSetup()
    }

    /// One consuming transfer before entering existing protected construction.
    /// The actual separately registered permit is already retained by TX.
    func takeAudioInstallation() throws
        -> (session: AudioSessionTransfer, reservation: MiMoV26AudioSidecarReservation)? {
        guard let audioLoadRequest else { return nil }
        let transaction = try requiredTransaction()
        let reservation = try transaction.audioReservationForInstallation(audioLoadRequest)
        return try lock.withLock {
            guard !cancelled, let audioSession else { throw MiMoV26ServingLoadError.invalidLifecycle }
            self.audioSession = nil
            return (AudioSessionTransfer(audioSession), reservation)
        }
    }

    /// Current-task primitive for the REAL Scheduler path. Its acquisition
    /// preparation is already registered. Do not start a second task/forwarder
    /// or fire/rebind its release token here.
    func prepareEncodedMediaInOwnedTask(
        normalized: ProviderPromptContractPipeline.NormalizedInput,
        controls: ChatTemplateControls, maximumOutputTokens: Int,
        sampling: MiMoV26EncodedVisualDecoder.Sampling,
        acquired: MultiModelBatchSchedulerEngine.AcquiredModel
    ) async throws -> (request: CBv2Request, engine: EngineV2) {
        guard let transaction, let policy = decodedMediaPolicy,
              let container = acquired.container, let bridge = acquired.engineV2Bridge,
              let lease = acquired.nativeConsumerLease, acquired.releaseToken.nativeBindingAccepted,
              transaction.matchesAcquisitionOwner(acquired) else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        try Task.checkCancellation()
        try validateDescriptor()
        try transaction.requireServingWorkAllowed()
        try transaction.registerDecodedMediaConsumer(lease,container:container,bridge:bridge)
        let plan = try MiMoV26EncodedMediaIngress.plan(normalized:normalized,controls:controls,
            maximumOutputTokens:maximumOutputTokens,policy:policy,allowAudio:decodedAudioPolicy != nil)
        let reservation = try transaction.beginEncodedMediaReservation(initialBytes:plan.initialBytes,
            hostBytes:plan.hostBytes,policy:policy,lease:lease)
        var prepared: (request: CBv2Request, engine: EngineV2)?
        do {
            try Task.checkCancellation()
            try transaction.requireServingWorkAllowed()
            let input = try await MiMoV26EncodedMediaIngress.decode(consume plan,sampling:sampling,reservation:reservation)
            try Task.checkCancellation()
            try validateDescriptor()
            try transaction.requireServingWorkAllowed()
            prepared = try await transaction.prepareDecodedMedia(input,policy:policy,
                expectedContainer:container,expectedBridge:bridge,existingReservation:reservation)
            try Task.checkCancellation()
            try validateDescriptor()
            try transaction.requireServingWorkAllowed()
            return prepared!
        } catch {
            if let prepared, let media = prepared.request.multimodal {
                prepared.engine.discardUnsubmittedNativeMedia(media)
            }
            // Native-adopted work is settled exclusively by the SDK callback;
            // unadopted decode work still waits for the actual host-task join.
            reservation.abortBeforeNativeAdoption()
            throw error
        }
    }

    /// Explicit decoded-PCM profile entry. Delegates to the SAME acquisition,
    /// preparation, terminal drainer and release token below; no second task.
    func submitDecodedAudioMedia(_ input: MiMoV26MultimodalInput,
        request: ChatCompletionRequest, acquired: consuming MultiModelBatchSchedulerEngine.AcquiredModel,
        firstContentDeadline: FirstContentDeadline? = nil
    ) async throws -> AsyncStream<GenerationEvent> {
        return try await submitOwnedDecodedMedia(input,request:request,acquired:consume acquired,
            firstContentDeadline:firstContentDeadline,requireAudioProfile:true)
    }

    /// Decoded visual/audio profile path. The caller has already
    /// acquired/reserved this exact published slot and owns its real release
    /// token. No HTTP capability or alternate model pipeline is introduced.
    func submitDecodedMedia(_ input: MiMoV26MultimodalInput,
        request: ChatCompletionRequest, acquired: consuming MultiModelBatchSchedulerEngine.AcquiredModel,
        firstContentDeadline: FirstContentDeadline? = nil
    ) async throws -> AsyncStream<GenerationEvent> {
        try await submitOwnedDecodedMedia(input,request:request,acquired:consume acquired,
            firstContentDeadline:firstContentDeadline,requireAudioProfile:false)
    }
    private func submitOwnedDecodedMedia(_ input: MiMoV26MultimodalInput,
        request: ChatCompletionRequest, acquired: consuming MultiModelBatchSchedulerEngine.AcquiredModel,
        firstContentDeadline: FirstContentDeadline?, requireAudioProfile: Bool
    ) async throws -> AsyncStream<GenerationEvent> {
        // Foreign bindings are never adopted, disposed, cancelled or released.
        guard let transaction, let lease = acquired.nativeConsumerLease,
              acquired.releaseToken.nativeBindingAccepted,
              transaction.matchesAcquisitionOwner(acquired) else {
            throw MiMoV26ServingLoadError.nativeOwnerMismatch
        }
        let release = acquired.releaseToken
        let payload = NativeLocalAcquisitionPayload(consume acquired)
        if Task.isCancelled {
            payload.discard()
            // The lease atomically refuses this for an existing preparation.
            do { try lease.discardUnstartedPreparation(); await release.fire() }
            catch { /* A duplicate must not dispose its first pipeline. */ }
            throw CancellationError()
        }
        let task: Task<AsyncStream<GenerationEvent>, Error>
        do {
            task = try lease.startPreparation {
                guard let owned = payload.take() else {
                    throw NativeLocalConsumerOwnershipError.invalidBinding
                }
                let id = UUID().uuidString
                let ownedBridge = owned.engineV2Bridge
                do {
                    try Task.checkCancellation()
                    try firstContentDeadline?.check()
                    guard let container = owned.container, let bridge = ownedBridge else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    // Content/lifecycle refusals now belong to a real task that
                    // has adopted the exact fresh handoff before it can fail.
                    guard let policy = self.decodedMediaPolicy,
                          !requireAudioProfile || self.decodedAudioPolicy != nil,
                          request.max_tokens == input.maximumOutputTokens,
                          request.top_logprobs == nil || request.top_logprobs == 0,
                          request.logprobs != true,
                          input.tools == nil, request.tools == nil, request.tool_choice == nil,
                          request.response_format == nil else {
                        throw MiMoV26ServingLoadError.managedLoadRequired
                    }
                    try transaction.validateContainerIdentity(container)
                    guard transaction.registeredBridgeForRetirement() === bridge else {
                        throw MiMoV26ServingLoadError.nativeOwnerMismatch
                    }
                    try transaction.registerDecodedMediaConsumer(lease, container: container, bridge: bridge)
                    if self.decodedAudioPolicy != nil {
                        let audio = try await bridge.nativeMiMoDecodedAudioBinding()
                        guard audio.load === self, audio.receipt.request == self.audioLoadRequest else {
                            throw MiMoV26ServingLoadError.nativeOwnerMismatch
                        }
                    }
                    try self.validateDescriptor()
                    let prepared = try await transaction.prepareDecodedMedia(input, policy: policy,
                        expectedContainer: container, expectedBridge: bridge)
                    defer {
                        if let media = prepared.request.multimodal {
                            prepared.engine.discardUnsubmittedNativeMedia(media)
                        }
                    }
                    try Task.checkCancellation()
                    try firstContentDeadline?.check()
                    try self.validateDescriptor()
                    try transaction.requireServingWorkAllowed()
                    let upstream = try await bridge.submitTokenized(
                        promptTokens: prepared.request.promptTokens, request: request,
                        requestId: id, cacheEnabled: false,
                        multimodal: prepared.request.multimodal, firstContentDeadline: firstContentDeadline)

                    // Register BEFORE the preparation task returns. Even close
                    // before registration gets an owned terminal drainer and
                    // the existing coalesced cancellation callback.
                    let forwarding = try MiMoV26ManagedMediaForwarding.handoff(
                        upstream: upstream, lease: lease, release: owned.releaseToken,
                        cancel: { await bridge.cancel(requestId: id) })
                    defer { forwarding.handoff.activate() }
                    do {
                        try Task.checkCancellation()
                        try self.validateDescriptor()
                        try transaction.requireServingWorkAllowed()
                    } catch {
                        // The bridge's actual terminal/fault wins. Never replace
                        // an already-produced upstream failure with cancellation.
                        forwarding.handoff.cancel()
                    }
                    return forwarding.stream
                } catch {
                    if let ownedBridge { await ownedBridge.cancel(requestId: id) }
                    await owned.releaseToken.fire()
                    throw error
                }
            }
        } catch {
            payload.discard()
            if let refusal = error as? NativeLocalConsumerOwnershipError, refusal == .closed {
                do { try lease.discardUnstartedPreparation(); await release.fire() }
                catch { /* An existing preparation/forwarder still owns it. */ }
            }
            throw error
        }
        // Install cancellation only after this call actually registered a task.
        // A duplicate caller must not cancel another call's existing pipeline.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { lease.closeAndCancel() }
    }

    func load() async throws -> ProviderModelContainer {
        let transaction = try lock.withLock {
            guard let transactionStorage, !loadStarted, !cancelled else {
                throw MiMoV26ServingLoadError.invalidLifecycle
            }
            loadStarted = true
            return transactionStorage
        }
        return try await withTaskCancellationHandler {
            // This operation spans tokenizer preparation as well as native work.
            // Revocation during the await cannot retire its still-future promise.
            try await transaction.performSetup {
                try self.recheck()
                let prepared = try await MiMoV26ModelFactory.prepare(request: self.request,
                    configuration: .init(directory: self.plan.canonicalRoot), tokenizerLoader: LocalTokenizerLoader())
                try self.recheck()
                let session = try self.lock.withLock {
                    guard let session = self.session else { throw MiMoV26ServingLoadError.invalidLifecycle }
                    self.session = nil
                    return session
                }
                let container = try await transaction.loadContainer(session: session, prepared: prepared)
                try self.recheck()
                return .nativeMiMo(container, self)
            }
        } onCancel: { self.revoke() }
    }

    func revoke() {
        let current = lock.withLock {
            cancelled = true
            return transactionStorage
        }
        current?.revoke()
    }

    /// The transaction invokes the actual engine/bridge completion path itself.
    /// Pending cancellation is not a permanent fault or permission to regrow.
    func finishFailureAfterUnwind() async -> MiMoV26NativeRetirement {
        revoke()
        guard let transaction else { return .notClaimed }
        let result = await transaction.retire()
        if case .retired = result { lock.withLock { session = nil; audioSession = nil } }
        return result
    }

    func sealConstructionForPublication() async throws -> NativeConstructionReceipt {
        try recheck()
        let transaction = try requiredTransaction()
        try await transaction.validateAudioOwnerForSetup()
        return try await transaction.sealConstructionForPublication()
    }

    /// Replace every old finishSetupAfterAccounting()+later insertion pair.
    /// Root's actual nonthrowing slot/session insertion belongs in this callback.
    func commitPublication<Result>(_ commit: () -> Result) throws -> Result {
        try validateDescriptor()
        return try requiredTransaction().commitPublication(commit)
    }

    func snapshot() -> MiMoV26PendingLoadReservation.Snapshot? { transaction?.snapshot().permit }

    static func preparation(mode: MTPMode, externalPath: String?,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            embeddedArtifactDeclared: Bool = true) throws -> SpecDecPreparation {
        guard externalPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw MiMoV26ServingLoadError.externalAssistantUnsupported
        }
        let enabled = mode.enablesMTP(forModelType: "mimo_v2", embeddedArtifactDeclared: embeddedArtifactDeclared)
        guard enabled else { return .init(artifact: nil, status: .disabled(.configDisabled, configured: false)) }
        guard embeddedArtifactDeclared else {
            return .init(artifact: nil, status: .disabled(.metadataMissing, configured: true))
        }
        guard SpecDecArtifactFunnel.killSwitchEnabled(environment: environment) else {
            return .init(artifact: nil, status: .disabled(.killSwitchDisabled, configured: true))
        }
        return .init(artifact: nil, status: .init(configured: true, active: false, reason: nil,
            source: .inline, revision: nil, artifactBytes: 0, assistantBytes: 0))
    }

    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Bound regular-file reads before allocation, reject symlink/FIFO/device
    /// leaves, compare opened identity and path state on both sides of the read.
    static func readMetadata(_ url: URL, limit: Int) throws -> Metadata {
        func state(_ value: stat) throws -> MiMoV26FilesystemObjectState {
            guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                let size = Int(exactly: value.st_size), size > 0, size <= limit else { throw MiMoV26ServingLoadError.metadata }
            return .init(device: String(value.st_dev), inode: String(value.st_ino), bytes: size,
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        }
        var before = stat()
        guard url.isFileURL, lstat(url.path, &before) == 0 else { throw MiMoV26ServingLoadError.metadata }
        let expected = try state(before)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw MiMoV26ServingLoadError.metadata }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, try state(opened) == expected else { throw MiMoV26ServingLoadError.changedDescriptor }
        var data = Data(count: expected.bytes)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MiMoV26ServingLoadError.metadata }
                offset += count
            }
        }
        var after = stat(), pathAfter = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
            try state(after) == expected, try state(pathAfter) == expected else { throw MiMoV26ServingLoadError.changedDescriptor }
        return .init(object: expected, bytes: data)
    }
}
