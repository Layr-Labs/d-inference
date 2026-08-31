import CryptoKit
import Foundation
import InferenceWorkerProtocol
import MLX
import MLXLMServer

public enum InferenceWorkerRuntimeError: Error, Sendable {
    case notConfigured
    case invalidConfiguration
    case artifactRejected
    case invalidRequest
    case frameLimit
    case responseTooLarge
    case execution
}
public typealias InferenceWorkerFrameSink =
    @Sendable (WorkerResponseFrame) async throws -> Void


private final class SecurityScopedModelCapability: @unchecked Sendable {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { url.stopAccessingSecurityScopedResource() }
}
private final class PrivateChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PrivateV2Chunk] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    func append(_ chunk: PrivateV2Chunk) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }


    func snapshot() -> [PrivateV2Chunk] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
private final class WorkerPartialResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ frame: String) {
        guard let parsed = WorkerInferenceSupport.parseStreamChunk(frame) else {
            return
        }
        lock.withLock {
            if let reasoning = parsed.reasoningDelta { text += reasoning }
            if let content = parsed.contentDelta { text += content }
            if let calls = parsed.toolCallsDelta, !calls.isEmpty {
                text += WorkerInferenceSupport.encodeToolCallsForHash(calls)
            }
        }
    }

    func snapshot() -> String {
        lock.withLock { text }
    }
}
private extension PrivateChunkCollector {
    func drain() -> [PrivateV2Chunk] {
        lock.lock()
        defer { lock.unlock() }
        let result = storage
        storage.removeAll(keepingCapacity: true)
        return result
    }
}
private final class WorkerFrameSequenceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(initialValue: UInt64) {
        value = initialValue
    }

    func take() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value &+= 1
        return current
    }
}

private final class LegacyStreamingFrameEncoder: @unchecked Sendable {
    private static let plaintextChunkBytes = 32 * 1024
    private let keyPair: NodeKeyPair
    private let sharedKey: Data
    private let requestIdentifier: String
    private let attestationSigner: (any AttestationSigner)?
    private let reasoningTokenCounter: @Sendable (String) async throws -> Int
    private var buffered = Data()
    private var sequence: UInt64 = 1
    private var responseBody = ""
    private var reasoningBody = ""
    private var emittedFirstCiphertext = false
    private(set) var reasoningTokens = 0

    init(
        keyPair: NodeKeyPair,
        recipientPublicKey: Data,
        requestIdentifier: String,
        attestationSigner: (any AttestationSigner)?,
        reasoningTokenCounter: @escaping @Sendable (String) async throws -> Int
    ) throws {
        self.keyPair = keyPair
        self.sharedKey = try keyPair.precomputeSharedKey(
            recipientPublicKey: recipientPublicKey)
        self.requestIdentifier = requestIdentifier
        self.attestationSigner = attestationSigner
        self.reasoningTokenCounter = reasoningTokenCounter
    }

    func consume(_ text: String, sink: InferenceWorkerFrameSink) async throws {
        var outbound = text
        if let parsed = WorkerInferenceSupport.parseStreamChunk(text) {
            if let content = parsed.contentDelta { responseBody += content }
            if let reasoning = parsed.reasoningDelta {
                responseBody += reasoning
                reasoningBody += reasoning
            }
            if let toolCalls = parsed.toolCallsDelta, !toolCalls.isEmpty {
                responseBody += WorkerInferenceSupport.encodeToolCallsForHash(toolCalls)
            }
            if let usage = parsed.usage, !reasoningBody.isEmpty {
                reasoningTokens = min(
                    max(0, try await reasoningTokenCounter(reasoningBody)),
                    max(0, usage.completionTokens))
                outbound = WorkerInferenceSupport.injectReasoningTokens(
                    into: text, reasoningTokens: reasoningTokens)
            }
        }
        let bytes = Data(outbound.utf8)
        var offset = 0
        while offset < bytes.count {
            let available = Self.plaintextChunkBytes - buffered.count
            let count = min(available, bytes.count - offset)
            buffered.append(bytes[offset..<(offset + count)])
            offset += count
            if buffered.count == Self.plaintextChunkBytes {
                try await flush(sink: sink)
            }
        }
        if !emittedFirstCiphertext, !buffered.isEmpty {
            try await flush(sink: sink)
        }
    }

    func consumeTerminalStop(
        _ stopSequence: String?,
        sink: InferenceWorkerFrameSink
    ) async throws {
        guard let stopSequence else { return }
        let object: [String: Any] = [
            "darkbloom_terminal": [
                "stop_reason": "stop_sequence",
                "stop_sequence": stopSequence,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw InferenceWorkerRuntimeError.execution
        }
        try await consume("data: \(json)\n\n", sink: sink)
    }

    func partialCompletionTokens() async throws -> Int {
        guard !responseBody.isEmpty else { return 0 }
        return max(0, try await reasoningTokenCounter(responseBody))
    }

    func finish(
        promptTokens: UInt64,
        completionTokens: UInt64,
        resultMetadataJSON: Data?,
        failureCode: Int = 0,
        statusCode: UInt16 = 0,
        sink: InferenceWorkerFrameSink
    ) async throws {
        if !buffered.isEmpty { try await flush(sink: sink) }
        let signData = "\(requestIdentifier):\(completionTokens):\(responseBody)"
        let responseHash = sha256Hex(Data(signData.utf8))
        let signature = try attestationSigner?
            .sign(Data(responseHash.utf8))
            .base64EncodedString()
        guard let terminal = WorkerResponseFrame(
            kind: .terminal, requestIdentifier: requestIdentifier,
            sequence: sequence,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            failureCode: failureCode,
            statusCode: statusCode,
            responseHash: responseHash,
            attestationSignature: signature,
            resultMetadataJSON: resultMetadataJSON,
            terminal: true) else {
            throw InferenceWorkerRuntimeError.frameLimit
        }
        try await sink(terminal)
    }

    private func flush(sink: InferenceWorkerFrameSink) async throws {
        guard sequence < UInt64(InferenceWorkerContract.maximumFramesPerRequest - 1) else {
            throw InferenceWorkerRuntimeError.frameLimit
        }
        let encrypted = try keyPair.encryptWithSharedKey(
            sharedKey, plaintext: buffered)
        guard let frame = WorkerResponseFrame(
            kind: .legacyEncryptedChunk, requestIdentifier: requestIdentifier,
            sequence: sequence, payload: encrypted,
            ephemeralPublicKey: keyPair.publicKeyBytes, terminal: false) else {
            throw InferenceWorkerRuntimeError.responseTooLarge
        }
        buffered.removeAll(keepingCapacity: true)
        sequence &+= 1
        emittedFirstCiphertext = true
        try await sink(frame)
    }

}
private actor WorkerFrameArrayCollector {
    private var frames: [WorkerResponseFrame] = []
    func append(_ frame: WorkerResponseFrame) { frames.append(frame) }
    func snapshot() -> [WorkerResponseFrame] { frames }
}



private struct WorkerAuthenticatedMetadata: Codable, Sendable {
    let cacheReceiptNonce: String?
    let cacheScope: String?
    let prefixCacheProtocol: Int?
    let toolSchemaMetadataProtocol: Int?
}

private final class WorkerPrefixReceiptCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lookup: WorkerPrefixLookupMetadata?
    private var ready: WorkerPrefixReadyMetadata?

    func recordLookup(_ result: PrefixCacheLookupResult) {
        lock.lock()
        if lookup == nil {
            lookup = WorkerPrefixLookupMetadata(
                outcome: result.outcome,
                tier: result.tier,
                cachedTokens: UInt64(max(0, result.cachedTokens)),
                prefillTokensSaved: UInt64(max(0, result.prefillTokensSaved)),
                stageMilliseconds: result.stageMs,
                promptAnchor: result.promptAnchor,
                matchedAnchor: result.matchedAnchor,
                requiredRecomputeTokens:
                    UInt64(max(0, result.requiredRecomputeTokens)))
        }
        lock.unlock()
    }

    func recordReady(_ result: PrefixCacheReadyResult) {
        lock.lock()
        ready = WorkerPrefixReadyMetadata(
            readyTokens: UInt64(max(0, result.readyTokens)),
            requiredRecomputeTokens:
                UInt64(max(0, result.requiredRecomputeTokens)),
            expectedPrefillTokensSaved:
                UInt64(max(0, result.expectedPrefillTokensSaved)),
            tier: result.tier,
            stageMilliseconds: result.stageMs,
            finalAnchor: result.finalAnchor)
        lock.unlock()
    }

    func snapshot() -> (
        lookup: WorkerPrefixLookupMetadata?,
        ready: WorkerPrefixReadyMetadata?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (lookup, ready)
    }
}

private final class WorkerArtifactRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: URL] = [:]
    private var hashes: [String: String] = [:]

    func replace(paths: [String: URL], hashes: [String: String]) {
        lock.lock()
        self.paths = paths
        self.hashes = hashes
        lock.unlock()
    }

    func path(for model: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return paths[model]
    }

    func hash(for model: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return hashes[model]
    }
}

private struct WorkerRuntimeConfiguration: Sendable {
    let server: StandaloneServer
    let registry: WorkerArtifactRegistry
    var models: [ModelInfo]
    var capabilities: [String: SecurityScopedModelCapability]
    var releaseBinaryHash: String
    var releaseGeneration: UInt64
    var modelGeneration: UInt64
    var modelCatalogJSON: Data
    var inferenceConfigurationJSON: Data
}

/// Plaintext boundary for the XPC service. This actor is the only owner of the
/// per-launch X25519 private key and of every object that can reach MLX/model
/// state. Its public API accepts and returns only the bounded ciphertext DTOs.
public actor InferenceWorkerRuntime {
    private let keyPair: NodeKeyPair
    private let launchIdentifier: String
    private let workerBinaryHash: String?
    private let metallibHash: String?
    private var answeredCodeChallengeDigests: Set<String> = []
    private var answeredCodeChallengeOrder: [String] = []
    private let runtimeCapabilities: Set<ProviderRuntimeCapability>
    private let runtimeCapabilitiesData: Data
    private let attestationSigner: (any AttestationSigner)?
    private let replayLedger = PrivateV2ReplayLedger()
    private var configuration: WorkerRuntimeConfiguration?
    private var snapshotSequence: UInt64 = 0
    private var idleEvictionTask: Task<Void, Never>?

    public init(attestationSigner: (any AttestationSigner)? = nil) {
        self.keyPair = NodeKeyPair.generate()
        self.launchIdentifier = UUID().uuidString.lowercased()
        self.workerBinaryHash = selfBinaryHash()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
        let metallibURL = executable.deletingLastPathComponent()
            .appendingPathComponent("mlx.metallib")
        let detected: Set<ProviderRuntimeCapability>
        if let hardware = try? HardwareDetector.detect() {
            detected = ProviderRuntimeCapabilityDetector.detectLive(
                hardware: hardware, metallibURL: metallibURL)
        } else {
            _ = bindRuntimeMetallibForMLX(from: metallibURL)
            detected = []
        }
        self.metallibHash = InferenceWorkerCore.metallibHash()
        self.runtimeCapabilities = detected
        self.runtimeCapabilitiesData =
            (try? JSONEncoder().encode(detected.sorted())) ?? Data("[]".utf8)
        if let attestationSigner {
            self.attestationSigner = attestationSigner
        } else {
            self.attestationSigner = try? PersistentEnclaveKey.loadOrCreateVerified()
        }
    }

    public nonisolated var processPublicKey: Data { keyPair.publicKeyBytes }
    public nonisolated var launchID: String { launchIdentifier }
    public nonisolated var workerBinarySHA256: String? { workerBinaryHash }
    public nonisolated var metallibSHA256: String? { metallibHash }

    public nonisolated var runtimeCapabilitiesJSON: Data {
        runtimeCapabilitiesData
    }

    public func answerCodeChallenge(
        _ request: WorkerCodeChallengeRequest
    ) throws -> WorkerCodeChallengeProof {
        guard request.launchIdentifier == launchIdentifier,
              let attestationSigner else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let plaintext = try keyPair.decrypt(
            senderPublicKey: request.senderPublicKey,
            ciphertext: request.ciphertext)
        guard let nonce = String(data: plaintext, encoding: .utf8),
              let nonceBytes = Data(base64Encoded: nonce),
              nonceBytes.count == 32 else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        var binding = Data("darkbloom/code-challenge-proof/v1\u{0}".utf8)
        binding.append(Data(launchIdentifier.utf8))
        var generation = request.connectionGeneration.bigEndian
        withUnsafeBytes(of: &generation) { binding.append(contentsOf: $0) }
        binding.append(nonceBytes)
        let digest = sha256Hex(binding)
        guard answeredCodeChallengeDigests.insert(digest).inserted else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        answeredCodeChallengeOrder.append(digest)
        if answeredCodeChallengeOrder.count > 256 {
            answeredCodeChallengeDigests.remove(
                answeredCodeChallengeOrder.removeFirst())
        }
        let signature = try attestationSigner.sign(Data(nonce.utf8))
            .base64EncodedString()
        guard let proof = WorkerCodeChallengeProof(
            launchIdentifier: launchIdentifier,
            connectionGeneration: request.connectionGeneration,
            nonce: nonce,
            signature: signature,
            bindingDigest: digest) else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        return proof
    }

    public func configure(
        _ input: WorkerBootstrapConfiguration
    ) async throws -> WorkerBootstrapResult {
        guard input.version == InferenceWorkerContract.version else {
            throw InferenceWorkerRuntimeError.invalidConfiguration
        }
        let models = try JSONDecoder().decode(
            [ModelInfo].self, from: input.modelCatalogJSON)
        guard models.count <= InferenceWorkerContract.maximumModels,
              Set(models.map(\.id)).count == models.count,
              Set(models.map(\.id)) == Set(input.artifacts.map(\.modelIdentifier)) else {
            throw InferenceWorkerRuntimeError.invalidConfiguration
        }
        var capabilities: [String: SecurityScopedModelCapability] = [:]
        var hashes: [String: String] = [:]
        let inferenceConfiguration = try JSONDecoder().decode(
            WorkerInferenceConfiguration.self,
            from: input.inferenceConfigurationJSON)
        var paths: [String: URL] = [:]
        for descriptor in input.artifacts {
            var stale = false
            let grantRoot = try URL(
                resolvingBookmarkData: descriptor.bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
            guard !stale, grantRoot.startAccessingSecurityScopedResource() else {
                throw InferenceWorkerRuntimeError.artifactRejected
            }
            let capability = SecurityScopedModelCapability(url: grantRoot)
            let declared = URL(fileURLWithPath: descriptor.canonicalPath)
                .standardizedFileURL
            let canonical = declared.resolvingSymlinksInPath()
            guard declared.path == canonical.path,
                  ModelArtifactBroker.isDescendant(canonical, of: grantRoot),
                  let actual = WeightHasher.computeHash(
                    snapshotDir: canonical,
                    modelID: descriptor.modelIdentifier),
                  actual == descriptor.manifestSHA256 else {
                throw InferenceWorkerRuntimeError.artifactRejected
            }
            capabilities[descriptor.modelIdentifier] = capability
            paths[descriptor.modelIdentifier] = canonical
            hashes[descriptor.modelIdentifier] = descriptor.manifestSHA256
        }
        if var previous = configuration,
           previous.modelCatalogJSON == input.modelCatalogJSON,
           previous.inferenceConfigurationJSON == input.inferenceConfigurationJSON,
           Set(previous.models.map(\.id)) == Set(models.map(\.id)),
           models.allSatisfy({ previous.registry.hash(for: $0.id) == hashes[$0.id] })
        {
            previous.capabilities = capabilities
            previous.releaseBinaryHash = input.releaseBinaryHash
            previous.releaseGeneration = input.releaseGeneration
            previous.modelGeneration = input.modelGeneration
            configuration = previous
            guard let result = WorkerBootstrapResult(
                acceptedModelIdentifiers: await previous.server.advertisedModelIds(),
                runtimeCapabilitiesJSON: runtimeCapabilitiesData)
            else {
                throw InferenceWorkerRuntimeError.invalidConfiguration
            }
            return result
        }
        let registry = WorkerArtifactRegistry()
        registry.replace(paths: paths, hashes: hashes)
        let server = StandaloneServer(
            config: StandaloneServerConfig(
                maxCachedModels: inferenceConfiguration.maximumCachedModels,
                runtimeCapabilities: runtimeCapabilities,
                engineV2MaxConcurrent:
                    inferenceConfiguration.engineV2MaximumConcurrent,
                engineV2MaxConcurrentByModel:
                    inferenceConfiguration.engineV2MaximumConcurrentByModel,
                engineV2KVBackend: inferenceConfiguration.engineV2KVBackend,
                engineV2KVBackendByModel:
                    inferenceConfiguration.engineV2KVBackendByModel,
                prefillDeadlineMode: inferenceConfiguration.prefillDeadlineMode,
                mtpMode: inferenceConfiguration.mtpMode),
            models: models,
            modelPathResolver: { registry.path(for: $0) },
            expectedModelHashResolver: { registry.hash(for: $0) })
        await server.startMaintenance()
        let previous = configuration
        configuration = WorkerRuntimeConfiguration(
            server: server,
            registry: registry,
            models: models,
            capabilities: capabilities,
            releaseBinaryHash: input.releaseBinaryHash,
            releaseGeneration: input.releaseGeneration,
            modelGeneration: input.modelGeneration,
            modelCatalogJSON: input.modelCatalogJSON,
            inferenceConfigurationJSON: input.inferenceConfigurationJSON)
        if let previous {
            await previous.server.shutdown()
        }
        idleEvictionTask?.cancel()
        if input.idleTimeoutMinutes > 0, let server = configuration?.server {
            let timeout = Duration.seconds(
                Int64(clamping: input.idleTimeoutMinutes) * 60)
            idleEvictionTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled { return }
                    await server.workerEvictIdleSlots(olderThan: timeout)
                }
            }
        } else {
            idleEvictionTask = nil
        }
        guard let server = configuration?.server,
              let result = WorkerBootstrapResult(
                acceptedModelIdentifiers: await server.advertisedModelIds(),
                runtimeCapabilitiesJSON: runtimeCapabilitiesData)
        else {
            throw InferenceWorkerRuntimeError.invalidConfiguration
        }
        return result
    }

    public func shutdown() async {
        idleEvictionTask?.cancel()
        idleEvictionTask = nil
        let previous = configuration
        configuration = nil
        if let previous {
            await previous.server.shutdown()
        }
    }
    public func execute(
        _ request: WorkerInferenceRequest
    ) async throws -> [WorkerResponseFrame] {
        let collector = WorkerFrameArrayCollector()
        try await executeStreaming(request) { frame in
            await collector.append(frame)
        }
        return await collector.snapshot()
    }

    public func executeStreaming(
        _ request: WorkerInferenceRequest,
        sink: @escaping InferenceWorkerFrameSink
    ) async throws {
        guard let configuration else { throw InferenceWorkerRuntimeError.notConfigured }
        guard request.version == InferenceWorkerContract.version, let kind = request.kind else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        switch kind {
        case .legacy:

            try await executeLegacy(request, configuration: configuration, sink: sink)
        case .privateV2:
            do {
                try await executePrivateV2(
                    request, configuration: configuration, sink: sink)
            } catch {
                if try await emitPrivateV2Failure(
                    request, underlying: error, sink: sink) {
                    return
                }
                throw error
            }
        }
    }

    public func preloadModel(identifier: String) async throws {
        guard let configuration,
              configuration.models.contains(where: { $0.id == identifier }) else {
            throw InferenceWorkerRuntimeError.notConfigured
        }
        let acquired = try await configuration.server.acquireModel(identifier)
        await acquired.releaseToken.fire()
    }

    public func capacitySnapshot(activeRequests: Int, queuedRequests: Int) async -> WorkerCapacitySnapshot {
        snapshotSequence &+= 1
        let facts = await configuration?.server.workerCapacityFacts() ?? []
        let generation = configuration?.modelGeneration ?? 0
        let entries = facts.compactMap { fact in
            let capacityJSON = fact.capacity.flatMap { try? JSONEncoder().encode($0) }
            return WorkerCapacityEntry(
                modelIdentifier: fact.modelIdentifier,
                state: fact.loaded ? 2 : 1,
                activeRequests: UInt16(clamping: fact.capacity?.numRunning ?? 0),
                queuedRequests: UInt16(clamping: fact.capacity?.numWaiting ?? 0),
                maximumRequests: UInt16(clamping: fact.capacity?.maxConcurrency ?? 0),
                desiredGeneration: generation,
                mtpState: fact.mtpModelIdentifier == nil ? 0 : 1,
                kvBytes: UInt64(max(0, fact.capacity?.kvBytesPerToken ?? 0)),
                capacityJSON: capacityJSON,
                manifestSHA256: fact.manifestHash,
                mtpModelIdentifier: fact.mtpModelIdentifier)
        }
        let active = UInt64(max(0, MLX.Memory.activeMemory))
        let peak = UInt64(max(0, MLX.Memory.peakMemory))
        let cache = UInt64(max(0, MLX.Memory.cacheMemory))
        let total = ProcessInfo.processInfo.physicalMemory
        let used = active.addingReportingOverflow(cache)
        let free = SystemMemory.availableBytes()
            ?? (used.overflow || used.partialValue >= total ? 0 : total - used.partialValue)
        let capabilities = facts.compactMap { $0.prefixCacheCapability }
            .sorted { $0.modelId < $1.modelId }
        let capableModels = Set(capabilities.map { $0.modelId })
        let statuses = facts.compactMap { $0.prefixCacheStatus }
            .filter {
                $0.state != .ready
                    || ($0.isConcreteReady && capableModels.contains($0.modelId))
            }
            .sorted { $0.modelId < $1.modelId }
        let readyModels = Set(
            statuses.lazy.filter { $0.isConcreteReady }.map { $0.modelId })
        let advertisedModels = capabilities.filter { readyModels.contains($0.modelId) }
        let prefixCacheAdvertisementJSON = try? JSONEncoder().encode(
            WorkerPrefixCacheAdvertisementMetadata(
                protocolVersion: advertisedModels.isEmpty ? 1 : 2,
                models: advertisedModels,
                statuses: statuses,
                donationOutcomes: PrefixCacheDonationTelemetry.shared.snapshot()))
        return WorkerCapacitySnapshot(
            launchIdentifier: launchIdentifier,
            sequence: snapshotSequence,
            entries: entries,
            gpuActiveBytes: active,
            gpuPeakBytes: peak,
            gpuCacheBytes: cache,
            totalMemoryBytes: total,
            freeForLoadBytes: free,
            prefixCacheAdvertisementJSON: prefixCacheAdvertisementJSON)!
    }

    private func executeLegacy(
        _ request: WorkerInferenceRequest,
        configuration: WorkerRuntimeConfiguration,
        sink: @escaping InferenceWorkerFrameSink
    ) async throws {
        guard let senderKey = request.senderPublicKey else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let plaintext: Data
        do {
            plaintext = try keyPair.decrypt(
                senderPublicKey: senderKey, ciphertext: request.envelope)
        } catch {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let metadata = try decodeMetadata(request.authenticatedMetadataJSON)
        if metadata.toolSchemaMetadataProtocol != ToolSchemaNormalization.metadataProtocolVersion,
           ToolSchemaNormalization.containsReservedMetadata(in: plaintext) {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let chatRequest = try WorkerInferenceSupport.decodeOpenAIRequest(plaintext)
        let receiptCollector = WorkerPrefixReceiptCollector()
        let usageSignal = EngineV2RequestUsageSignal(
            onLookupResolved: { receiptCollector.recordLookup($0) },
            onCacheReady: { receiptCollector.recordReady($0) })
        let encoder = try LegacyStreamingFrameEncoder(
            keyPair: keyPair, recipientPublicKey: senderKey,
            requestIdentifier: request.requestIdentifier,
            attestationSigner: attestationSigner,
            reasoningTokenCounter: { reasoning in
                let tokenizer = try await configuration.server.resolveTokenizer(
                    chatRequest.model)
                return tokenizer.tokenizer.inner.encode(
                    text: reasoning, addSpecialTokens: false).count
            })
        let result: ChatResult
        do {
            result = try await runChat(
                chatRequest: chatRequest,
                plaintext: plaintext,
                server: configuration.server,
                cacheScope: metadata.cacheScope ?? "",
                firstContentDeadlineUptimeNanoseconds:
                    request.firstContentDeadlineUptimeNanoseconds,
                usageSignal: usageSignal,
                onAdmitted: {
                    guard let accepted = WorkerResponseFrame(
                        kind: .accepted,
                        requestIdentifier: request.requestIdentifier,
                        sequence: 0,
                        terminal: false) else {
                        throw InferenceWorkerRuntimeError.execution
                    }
                    try await sink(accepted)
                },
                onFrame: { frame in
                    try await encoder.consume(frame, sink: sink)
                })
        } catch is CancellationError {
            let completionTokens = UInt64(
                max(0, try await encoder.partialCompletionTokens()))
            let usage = UsageInfo(
                promptTokens: 0,
                completionTokens: completionTokens,
                reasoningTokens: UInt64(max(0, encoder.reasoningTokens)))
            let terminalMetadata = WorkerTerminalMetadata(
                cacheReceiptNonce: metadata.cacheReceiptNonce,
                prefixCacheProtocol: metadata.prefixCacheProtocol,
                lookup: nil, ready: nil, lookupV2: nil, readyV2: nil,
                reasoningTokens: usage.reasoningTokens,
                errorReason: .cancelled,
                terminalCause: .cancelled,
                attemptUsage: usage)
            try await encoder.finish(
                promptTokens: 0,
                completionTokens: completionTokens,
                resultMetadataJSON: try JSONEncoder().encode(terminalMetadata),
                failureCode: InferenceWorkerErrorCode.cancelled.rawValue,
                statusCode: completionTokens == 0 ? 499 : 200,
                sink: sink)
            return
        }
        let receipts = receiptCollector.snapshot()
        let v2Evidence = await makePrefixCacheV2Evidence(
            requestIdentifier: request.requestIdentifier,
            modelIdentifier: chatRequest.model,
            nonce: metadata.prefixCacheProtocol == 2
                ? metadata.cacheReceiptNonce : nil,
            lookup: receipts.lookup,
            ready: receipts.ready,
            server: configuration.server)
        let terminalMetadata = WorkerTerminalMetadata(
            cacheReceiptNonce: metadata.cacheReceiptNonce,
            prefixCacheProtocol: metadata.prefixCacheProtocol,
            lookup: receipts.lookup,
            ready: receipts.ready,
            lookupV2: v2Evidence.lookup,
            readyV2: v2Evidence.ready,
            reasoningTokens: UInt64(max(0, encoder.reasoningTokens)))
        let terminalMetadataJSON = try JSONEncoder().encode(terminalMetadata)
        try await encoder.consumeTerminalStop(result.stopSequence, sink: sink)
        try await encoder.finish(
            promptTokens: UInt64(max(0, result.promptTokens)),
            completionTokens: UInt64(max(0, result.completionTokens)),
            resultMetadataJSON: terminalMetadataJSON,
            sink: sink)
    }
    private func makePrefixCacheV2Evidence(
        requestIdentifier: String,
        modelIdentifier: String?,
        nonce: String?,
        lookup: WorkerPrefixLookupMetadata?,
        ready: WorkerPrefixReadyMetadata?,
        server: StandaloneServer
    ) async -> (
        lookup: WorkerPrefixLookupV2Metadata?,
        ready: WorkerPrefixReadyV2Metadata?
    ) {
        guard let nonce,
              let lookup,
              let lookupTier = lookup.tier,
              lookupTier == .ssd,
              validPrefixStageMilliseconds(lookup.stageMilliseconds),
              let promptAnchor = lookup.promptAnchor,
              let capability = await server.workerPrefixCacheV2Capability(
                modelIdentifier: modelIdentifier),
              validPrefixAnchor(promptAnchor, capability: capability)
        else { return (nil, nil) }
        if lookup.outcome == .hit {
            guard let matched = lookup.matchedAnchor,
                  validPrefixAnchor(matched, capability: capability),
                  matched.tokenCount <= promptAnchor.tokenCount,
                  lookup.requiredRecomputeTokens <= matched.tokenCount,
                  lookup.prefillTokensSaved
                    == matched.tokenCount - lookup.requiredRecomputeTokens
            else { return (nil, nil) }
        } else {
            guard lookup.matchedAnchor == nil,
                  lookup.requiredRecomputeTokens == 0,
                  lookup.prefillTokensSaved == 0
            else { return (nil, nil) }
        }
        guard let lookupSequence =
                await server.workerTakeNextPrefixCacheV2Sequence(
                    modelIdentifier: modelIdentifier,
                    expectedEpoch: capability.cacheEpoch)
        else { return (nil, nil) }
        let lookupMessage = WorkerPrefixLookupV2Metadata(
            requestId: requestIdentifier,
            cacheReceiptNonce: nonce,
            modelId: capability.modelId,
            modelAggregateHash: capability.modelAggregateHash,
            promptContractId: capability.promptContractId,
            cacheEpoch: capability.cacheEpoch,
            cacheSeq: lookupSequence,
            promptAnchor: promptAnchor,
            matchedAnchor: lookup.matchedAnchor,
            outcome: lookup.outcome,
            tier: lookupTier,
            requiredRecomputeTokens: lookup.requiredRecomputeTokens,
            expectedPrefillTokensSaved: lookup.prefillTokensSaved,
            stageMs: lookup.stageMilliseconds)
        guard let ready,
              ready.tier == .ssd,
              validPrefixStageMilliseconds(ready.stageMilliseconds),
              let finalAnchor = ready.finalAnchor,
              validPrefixAnchor(finalAnchor, capability: capability),
              finalAnchor.tokenCount >= promptAnchor.tokenCount,
              ready.requiredRecomputeTokens <= finalAnchor.tokenCount,
              ready.expectedPrefillTokensSaved
                == finalAnchor.tokenCount - ready.requiredRecomputeTokens,
              let readySequence =
                await server.workerTakeNextPrefixCacheV2Sequence(
                    modelIdentifier: modelIdentifier,
                    expectedEpoch: capability.cacheEpoch)
        else { return (lookupMessage, nil) }
        var anchors = [promptAnchor]
        if finalAnchor != promptAnchor { anchors.append(finalAnchor) }
        return (
            lookupMessage,
            WorkerPrefixReadyV2Metadata(
                requestId: requestIdentifier,
                cacheReceiptNonce: nonce,
                modelId: capability.modelId,
                modelAggregateHash: capability.modelAggregateHash,
                promptContractId: capability.promptContractId,
                cacheEpoch: capability.cacheEpoch,
                cacheSeq: readySequence,
                tier: ready.tier,
                readyAnchors: anchors,
                requiredRecomputeTokens: ready.requiredRecomputeTokens,
                expectedPrefillTokensSaved: ready.expectedPrefillTokensSaved,
                stageMs: ready.stageMilliseconds))
    }

    private func validPrefixAnchor(
        _ anchor: PrefixCacheAnchor,
        capability: PrefixCacheV2Capability
    ) -> Bool {
        capability.blockSize > 0
            && anchor.tokenCount > 0
            && anchor.tokenCount <= 1_000_000
            && anchor.tokenCount.isMultiple(of: UInt64(capability.blockSize))
            && anchor.chainHash.count == 64
            && anchor.chainHash.allSatisfy {
                $0.isNumber || ("a" ... "f").contains(String($0))
            }
    }

    private func validPrefixStageMilliseconds(_ value: Double?) -> Bool {
        guard let value else { return true }
        return value.isFinite && value >= 0 && value <= 600_000
    }

    private func emitPrivateV2Failure(
        _ input: WorkerInferenceRequest,
        underlying: Error,
        sink: @escaping InferenceWorkerFrameSink
    ) async throws -> Bool {
        guard let request = try? JSONDecoder().decode(
                PrivateV2Request.self, from: input.envelope),
              request.requestId == input.requestIdentifier,
              let transcriptDigest = try? Base64URL.decode(request.transcriptDigest),
              transcriptDigest.count == 32,
              PrivateV2Crypto.constantTimeEqual(
                transcriptDigest, PrivateV2Transcript(request: request).digest()),
              let clientPublicKey = try? Base64URL.decode(request.clientPublicKey),
              let salt = try? Base64URL.decode(request.kdfSalt),
              clientPublicKey.count == 32, salt.count == 32,
              let keys = try? keyPair.privateV2KeyMaterial(
                clientPublicKey: clientPublicKey,
                salt: salt,
                transcriptDigest: transcriptDigest) else {
            return false
        }
        let failure = WorkerInferenceSupport.sanitizedInferenceFailure(
            from: underlying, phase: .generation)
        let failureCode = failure.code.rawValue
        let status = Int(failure.statusCode)
        let collector = PrivateChunkCollector()
        let writer = PrivateV2ChunkWriter(
            requestId: request.requestId,
            transcriptDigest: transcriptDigest,
            responseKey: keys.responseKey,
            sink: { collector.append($0) })
        try writer.emit(
            payload: PrivateV2EndpointAdapter.errorPayload(
                endpoint: request.endpoint, failureCode: failureCode),
            terminal: true,
            failureCode: failureCode,
            statusCode: status)
        writer.finish()
        for chunk in collector.drain() {
            let encoded = try JSONEncoder().encode(chunk)
            guard let frame = WorkerResponseFrame(
                kind: .privateV2EncryptedChunk,
                requestIdentifier: request.requestId,
                sequence: chunk.sequence,
                payload: encoded,
                failureCode: 0,
                statusCode: 0,
                terminal: true) else {
                throw InferenceWorkerRuntimeError.responseTooLarge
            }
            try await sink(frame)
        }
        return true
    }

    private func executePrivateV2(
        _ input: WorkerInferenceRequest,
        configuration: WorkerRuntimeConfiguration,
        sink: @escaping InferenceWorkerFrameSink
    ) async throws {
        let request = try JSONDecoder().decode(PrivateV2Request.self, from: input.envelope)
        guard request.requestId == input.requestIdentifier,
              request.version == PrivateV2Protocol.version else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let deadline = try PrivateV2Date.parse(request.deadline)
        let now = Date()
        guard deadline > now,
              deadline.timeIntervalSince(now) <= PrivateV2Protocol.maximumLeaseLifetime else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let transcriptDigest = try Base64URL.decode(request.transcriptDigest)
        let clientPublicKey = try Base64URL.decode(request.clientPublicKey)
        let salt = try Base64URL.decode(request.kdfSalt)
        let nonce = try Base64URL.decode(request.nonce)
        let ciphertext = try Base64URL.decode(request.ciphertext)
        guard transcriptDigest.count == 32, clientPublicKey.count == 32,
              salt.count == 32, nonce.count == 12,
              PrivateV2Crypto.constantTimeEqual(
                transcriptDigest, PrivateV2Transcript(request: request).digest()) else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        let keys = try keyPair.privateV2KeyMaterial(
            clientPublicKey: clientPublicKey, salt: salt,
            transcriptDigest: transcriptDigest)
        let plaintext = try PrivateV2Crypto.open(
            ciphertext, key: keys.requestKey, nonce: nonce,
            aad: try PrivateV2Crypto.requestAAD(transcriptDigest: transcriptDigest))
        // Authentication succeeds before the durable one-use claim. The ledger
        // lock then makes concurrent valid replays an atomic single winner.
        try replayLedger.claim(
            leaseId: request.leaseId, requestId: request.requestId,
            expiresAt: deadline, now: now)
        let inner = try PrivateV2InnerRequest.decode(plaintext)
        guard let manifestHash = configuration.models.first(
            where: { $0.id == request.model })?.weightHash else {
            throw InferenceWorkerRuntimeError.invalidRequest
        }
        try PrivateV2IdentityValidator.validate(
            inner: inner, outer: request,
            currentReleaseBinaryHash: configuration.releaseBinaryHash,
            currentReleaseGeneration: configuration.releaseGeneration,
            currentModelManifestHash: manifestHash,
            currentModelGeneration: configuration.modelGeneration)
        let chatBody = try PrivateV2EndpointAdapter.chatRequestBody(
            endpoint: request.endpoint, model: request.model, stream: request.stream,
            requestedMaxOutputTokens: request.requestedMaxOutputTokens,
            defaultMaxOutputTokens: UInt64(WorkerInferenceSupport.schedulerDefaultMaxTokens),
            requiresVision: request.requiresVision, body: inner.body)
        let chatRequest = try WorkerInferenceSupport.decodeOpenAIRequest(chatBody)
        let adapter = PrivateV2NativeStreamAdapter(
            endpoint: request.endpoint, requestId: request.requestId, model: request.model)
        let chunks = PrivateChunkCollector()
        let partialResponse = WorkerPartialResponseCollector()
        let outerSequence = WorkerFrameSequenceCounter(initialValue: 1)
        let writer = PrivateV2ChunkWriter(
            requestId: request.requestId,
            transcriptDigest: transcriptDigest,
            responseKey: keys.responseKey,
            initialSequence: 0,
            sink: { chunks.append($0) })

        let emitAvailable: @Sendable () async throws -> Void = {
            for chunk in chunks.drain() {
                let encoded = try JSONEncoder().encode(chunk)
                guard let frame = WorkerResponseFrame(
                    kind: .privateV2EncryptedChunk,
                    requestIdentifier: request.requestId,
                    sequence: outerSequence.take(), payload: encoded,
                    promptTokens: chunk.usage?.promptTokens ?? 0,
                    completionTokens: chunk.usage?.completionTokens ?? 0,
                    failureCode: 0, statusCode: 0, terminal: chunk.terminal) else {
                    throw InferenceWorkerRuntimeError.responseTooLarge
                }
                try await sink(frame)
            }
        }
        guard let accepted = WorkerResponseFrame(
            kind: .accepted,
            requestIdentifier: request.requestId,
            sequence: 0,
            terminal: false) else {
            throw InferenceWorkerRuntimeError.execution
        }
        try await sink(accepted)
        do {
            let result = try await runChat(
                chatRequest: chatRequest, plaintext: chatBody,
                server: configuration.server, cacheScope: "",
                firstContentDeadlineUptimeNanoseconds:
                    input.firstContentDeadlineUptimeNanoseconds,
                usageSignal: nil,
                onAdmitted: {},
                onFrame: { frame in
                    partialResponse.append(frame)
                    for payload in adapter.payloads(fromSSE: frame) {
                        try writer.emit(payload: payload, terminal: false)
                    }
                    try await emitAvailable()
                })
            let usage = PrivateV2Usage(
                promptTokens: UInt64(max(0, result.promptTokens)),
                completionTokens: UInt64(max(0, result.completionTokens)))
            for payload in adapter.closingPayloads(
                usage: usage, stopSequence: result.stopSequence) {
                try writer.emit(payload: payload, terminal: false)
                try await emitAvailable()
            }
            try writer.emit(
                payload: adapter.terminalPayload(usage: usage),
                terminal: true, usage: usage)
            writer.finish()
            try await emitAvailable()
        } catch {
            let failure = WorkerInferenceSupport.sanitizedInferenceFailure(
                from: error, phase: .generation)
            let failureCode = failure.code.rawValue
            let statusCode = Int(failure.statusCode)
            var usage = failure.attemptUsage.map {
                PrivateV2Usage(
                    promptTokens: $0.promptTokens,
                    completionTokens: $0.completionTokens)
            }
            if usage == nil {
                let text = partialResponse.snapshot()
                if !text.isEmpty {
                    let tokenizer = try await configuration.server.resolveTokenizer(
                        chatRequest.model)
                    let count = tokenizer.tokenizer.inner.encode(
                        text: text, addSpecialTokens: false).count
                    usage = PrivateV2Usage(
                        promptTokens: 0,
                        completionTokens: UInt64(max(0, count)))
                }
            }
            try writer.emit(
                payload: PrivateV2EndpointAdapter.errorPayload(
                    endpoint: request.endpoint, failureCode: failureCode),
                terminal: true,
                usage: usage,
                failureCode: failureCode,
                statusCode: statusCode)
            writer.finish()
            try await emitAvailable()
        }
    }


    private struct ChatResult {
        let promptTokens: Int
        let completionTokens: Int
        let stopSequence: String?
    }

    private func runChat(
        chatRequest: OpenAIChatCompletionRequest,
        plaintext: Data,
        server: StandaloneServer,
        cacheScope: String,
        firstContentDeadlineUptimeNanoseconds: UInt64,
        usageSignal: EngineV2RequestUsageSignal?,
        onAdmitted: @escaping @Sendable () async throws -> Void,
        onFrame: @escaping @Sendable (String) async throws -> Void
    ) async throws -> ChatResult {
        let templateControls = WorkerInferenceSupport.extractChatTemplateControls(from: plaintext)
        let deadline: FirstContentDeadline?
        if firstContentDeadlineUptimeNanoseconds > 0 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard firstContentDeadlineUptimeNanoseconds > now else {
                throw PreContentDeadlineFailure.deadlineUnreachable
            }
            let remaining = firstContentDeadlineUptimeNanoseconds - now
            let roundedMilliseconds = remaining / 1_000_000
                + (remaining.isMultiple(of: 1_000_000) ? 0 : 1)
            let milliseconds = max(1, Int64(clamping: roundedMilliseconds))
            deadline = FirstContentDeadline(
                relativeBudgetMilliseconds: milliseconds)
        } else {
            deadline = nil
        }
        let logprobsSpec = WorkerInferenceSupport.extractLogprobsSpec(from: plaintext)
        let logprobsChannel = logprobsSpec?.requested == true
            ? EngineV2LogprobsChannel() : nil
        let logprobsPlumbing = logprobsChannel.map {
            EngineV2LogprobsPlumbing(
                topLogprobs: logprobsSpec?.topLogprobs, channel: $0)
        }
        let engine = MultiModelBatchSchedulerEngine(
            acquire: { modelID in try await server.acquireModel(modelID) },
            tokenizerProvider: { modelID in try await server.resolveTokenizer(modelID) },
            availableModels: { await server.advertisedModelIds() },
            defaultMaxTokens: WorkerInferenceSupport.schedulerDefaultMaxTokens,
            templateControls: templateControls,
            cacheScope: cacheScope,
            cacheEnabled: !cacheScope.isEmpty,
            engineV2Logprobs: logprobsPlumbing,
            engineV2Sampling: WorkerInferenceSupport.extractSamplingOverrides(from: plaintext),
            engineV2Usage: usageSignal,
            firstContentDeadline: deadline,
            allowInternalToolSchemaMetadata: true)
        var streaming = chatRequest
        streaming.stream = true
        let modelType = configuration?.models.first {
            $0.id == chatRequest.model
        }?.modelType
        streaming.reasoningParser =
            WorkerInferenceSupport.inferReasoningParser(for: modelType)
        var options = streaming.streamOptions ?? OpenAIStreamOptions()
        options.includeUsage = true
        streaming.streamOptions = options
        let service = MLXOpenAIService(engine: engine)
        let stream = try await service.streamChatCompletionFrames(request: streaming)
        try await onAdmitted()

        var prompt = 0
        var completion = 0
        var pendingLogprobs: [SSETokenLogprob] = []
        for try await rawFrame in stream {
            try Task.checkCancellation()
            var frame = rawFrame
            if let logprobsChannel {
                pendingLogprobs.append(contentsOf: logprobsChannel.drain())
                _ = EngineV2LogprobsChannel.capPending(&pendingLogprobs)
                if let rewritten = WorkerInferenceSupport.injectLogprobs(
                    into: frame, entries: pendingLogprobs)
                {
                    frame = rewritten
                    pendingLogprobs.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            let bytes = frame.utf8.count
            guard bytes <= InferenceWorkerContract.maximumRequestBytes else {
                throw InferenceWorkerRuntimeError.responseTooLarge
            }
            try await onFrame(frame)
            if let extract = WorkerInferenceSupport.parseStreamChunk(frame) {
                if let usage = extract.usage {
                    prompt = usage.promptTokens
                    completion = usage.completionTokens
                }
            }
        }
        return ChatResult(
            promptTokens: prompt,
            completionTokens: completion,
            stopSequence: usageSignal?.matchedStopSequence)
    }


    private func decodeMetadata(_ data: Data?) throws -> WorkerAuthenticatedMetadata {
        guard let data else {
            return WorkerAuthenticatedMetadata(
                cacheReceiptNonce: nil, cacheScope: nil,
                prefixCacheProtocol: nil, toolSchemaMetadataProtocol: nil)
        }
        return try JSONDecoder().decode(WorkerAuthenticatedMetadata.self, from: data)
    }
}
