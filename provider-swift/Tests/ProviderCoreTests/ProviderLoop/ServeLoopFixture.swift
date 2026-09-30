import CryptoKit
import Foundation
import Testing

@testable import ProviderCore

/// Signs with a software P-256 key, so registration and challenge replies
/// carry a real signature without the Secure Enclave.
struct ServeLoopTestSigner: AttestationSigner {
    private let keyData: Data
    let publicKeyBase64: String

    init() {
        let key = P256.Signing.PrivateKey()
        keyData = key.rawRepresentation
        publicKeyBase64 = key.publicKey.rawRepresentation.base64EncodedString()
    }

    func sign(_ data: Data) throws -> Data {
        try P256.Signing.PrivateKey(rawRepresentation: keyData)
            .signature(for: data).derRepresentation
    }
}

/// Runs `ProviderLoop.run()` against a `MockCoordinator` on a loopback port.
/// One scripted engine serves `modelId`: no weights, no GPU work, and no
/// network beyond 127.0.0.1. Every file the loop writes goes to `directory`.
struct ServeLoopFixture: Sendable {
    static let modelId = "serve-loop-fixture"

    let mock: MockCoordinator
    let loop: ProviderLoop
    let engine: PrefillScriptEngine
    let bridge: EngineV2Bridge
    let runtime: EngineV2Runtime
    let signer: ServeLoopTestSigner
    let directory: URL
    let coordinatorURL: String

    var stateFile: URL { directory.appendingPathComponent("state.json") }

    static func make(
        heartbeatIntervalSecs: UInt64 = 60,
        privateOnly: Bool = false
    ) async throws -> ServeLoopFixture {
        let mock = MockCoordinator()
        let coordinatorURL = try await mock.start().mockProviderWebSocketURL()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("serve-loop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        }
        let hardware = HardwareInfo(
            machineModel: "Mac16,5", chipName: "Apple M4 Max",
            chipFamily: .m4, chipTier: .max, memoryGb: 64, memoryAvailableGb: 64,
            cpuCores: .init(total: 16, performance: 12, efficiency: 4),
            gpuCores: 40, memoryBandwidthGbs: 546)
        let signer = ServeLoopTestSigner()
        let loop = try ProviderLoop(
            config: .init(
                coordinatorURL: coordinatorURL, hardware: hardware, models: [],
                config: .init(
                    provider: .init(name: "serve-loop", autoUpdate: false),
                    backend: .init(),
                    coordinator: .init(
                        url: coordinatorURL,
                        heartbeatIntervalSecs: heartbeatIntervalSecs,
                        privateOnly: privateOnly))),
            attestationSigner: signer, kvBudgetForTesting: budget)
        await loop.setServeUsesHostServicesForTesting(false)
        await loop.setDaemonStateFileForTesting(directory.appendingPathComponent("state.json"))
        await loop.setLoadedModelsFileForTesting(directory.appendingPathComponent("loaded-models.json"))

        let engine = PrefillScriptEngine()
        let tokenizer = CancelledPrefixTokenizer(prompt: [1, 2, 3])
        let bridge = EngineV2Bridge(
            engine: engine, modelId: modelId,
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [],
            kvBytesPerToken: 4_000, kvBudget: budget)
        let runtime = EngineV2Runtime()
        await runtime.register(modelId: modelId, bridge: bridge)
        await loop.setEngineV2RuntimeForTesting(runtime)
        await loop.installModelSlotForTesting(
            modelId: modelId,
            container: cancelledPrefixContainer(tokenizer: tokenizer),
            tokenizer: TokenizerHandle(tokenizer), engineV2: bridge,
            sizing: .init(
                weightsBytes: 0, fp16KVBytesPerToken: 4_000,
                maxContextLength: 8192, defaultMaxTokens: 4096))

        return ServeLoopFixture(
            mock: mock, loop: loop, engine: engine, bridge: bridge, runtime: runtime,
            signer: signer, directory: directory, coordinatorURL: coordinatorURL)
    }

    /// Starts the serve loop. The caller ends it with `stop(_:)`.
    func start() -> Task<Void, Error> {
        let loop = self.loop
        return Task { try await loop.run() }
    }

    /// Waits for the first registration of the running loop.
    func awaitRegistration() async throws -> ProviderMessage.Register {
        let register = try await mock.awaitFirstRegister(timeout: .seconds(15))
        return try #require(register)
    }

    /// Cancels the serve task (the path a SIGTERM takes), waits for `run()`
    /// to return, and removes everything the fixture made.
    @discardableResult
    func stop(_ task: Task<Void, Error>, within timeout: Duration = .seconds(30)) async -> Bool {
        task.cancel()
        let returned = await Self.finishes(task, within: timeout)
        await mock.shutdown()
        await bridge.shutdown()
        _ = await runtime.unregister(modelId: Self.modelId)
        try? FileManager.default.removeItem(at: directory)
        return returned
    }

    /// Encrypts a chat request to the provider and pushes it. The caller
    /// keeps `consumer` to decrypt the response chunks.
    func pushChatRequest(
        requestId: String,
        consumer: NodeKeyPair = NodeKeyPair.generate(),
        body: Data? = nil
    ) async throws {
        let providerKey = await loop.keyPair.publicKeyBase64
        let request = try body ?? JSONSerialization.data(withJSONObject: [
            "model": Self.modelId,
            "messages": [["role": "user", "content": "fixture"]],
            "max_tokens": 1, "stream": true, "reasoning_parser": "none",
        ])
        try await mock.pushInferenceRequest(
            requestId: requestId, providerPublicKeyBase64: providerKey,
            chatRequestJSON: request, consumerKeyPair: consumer)
    }

    /// Waits until the engine has `count` submitted streams.
    func awaitSubmissions(_ count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while engine.continuations.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(engine.continuations.count >= count)
    }

    /// Waits until the engine has received `count` cancellations.
    func awaitEngineCancellations(_ count: Int, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while engine.cancelledRequestIDs.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(engine.cancelledRequestIDs.count >= count)
    }

    /// Finishes submission `index` with one token of text "a".
    func completeSubmission(_ index: Int) {
        let continuation = engine.continuations[index]
        continuation.yield(.delta(text: "a", tokens: [5], logprobs: nil))
        continuation.yield(.finished(
            reason: .length, usage: .init(promptTokens: 3, completionTokens: 1)))
        continuation.finish()
    }

    /// Terminal frames (complete or error) the coordinator got for `requestId`.
    static func terminalCount(_ snapshot: CapturedMessages, requestId: String) -> Int {
        snapshot.inferenceComplete.filter { $0.requestId == requestId }.count
            + snapshot.inferenceErrors.filter { $0.requestId == requestId }.count
    }

    static func finishes(_ task: Task<Void, Error>, within timeout: Duration) async -> Bool {
        let done = ServeLoopFlag()
        Task {
            _ = try? await task.value
            done.set()
        }
        let deadline = ContinuousClock.now + timeout
        while !done.value, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done.value
    }
}

final class ServeLoopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}
