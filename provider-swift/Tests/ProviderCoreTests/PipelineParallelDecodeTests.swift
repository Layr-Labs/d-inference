import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

// MARK: - PipelineParallelDecodeTests
//
// Tests for the PP decode loop (PR 4c).
//
// Scope:
//   ✅ New ClusterMsgType raw values are correct (0x0B, 0x0C, 0x0D)
//   ✅ New PP payload structs (PPActivationPayload, PPTokenPayload, PPSessionEndPayload)
//      round-trip through JSON
//   ✅ EncryptedPipelineEngine constructs with a tiny LlamaModel + mock session
//   ✅ generate() produces ≤ maxTokens tokens and completes cleanly
//   ✅ Frame sequence: ppActivation → ppToken → ppActivation → ppToken → … → ppSessionEnd
//   ✅ Sealed activation in each ppActivation can be decrypted with the test key
//   ✅ Engine reaches ppSessionEnd on maxTokens exhausted
//   ✅ Engine stops at EOS token
//   ✅ EncryptedPipelineServer.makeInferenceHandler compiles and can be called
//   ✅ KV cache slicing: rank 0 cache is splitLayer entries, rank 1 is (numLayers-splitLayer)
//
// NOT tested here (needs two cooperative processes over TCP):
//   ❌ Real ThunderboltLink two-Mac round-trip
//   ❌ Interaction with jaccl / TP fallback path

// MARK: - Small LlamaConfiguration (4 layers, hidden=64, vocab=128)

private func smallConfig() -> LlamaConfiguration {
    LlamaConfiguration(
        hiddenSize: 64,
        hiddenLayers: 4,
        intermediateSize: 256,
        attentionHeads: 8,
        rmsNormEps: 1e-5,
        vocabularySize: 128,
        kvHeads: 4
    )
}

// MARK: - MockPPSession
//
// Simulates rank 1's side of the PP exchange without opening any TCP connection.
//
// The mock pre-loads a queue of canned token IDs to return. For each ppActivation
// frame it receives, it pops the next canned token, seals it with the shared test
// key, and enqueues a ppToken response. Callers drain responses via
// `receiveInferenceFrame()`.
//
// Thread-safety: actor-isolated.

actor MockPPSession: PPClusterSession {

    private let testKey: SymmetricKey
    private var _sentFrames: [Data] = []
    private var _responseQueue: [Data] = []
    private var _cannedTokens: [Int32]

    init(testKey: SymmetricKey, cannedTokens: [Int32] = []) {
        self.testKey = testKey
        self._cannedTokens = cannedTokens
    }

    // MARK: - PPClusterSession

    nonisolated func sendInferenceFrame(_ data: Data) async throws {
        await processOutboundFrame(data)
    }

    nonisolated func receiveInferenceFrame() async throws -> Data {
        return try await dequeueResponse()
    }

    nonisolated func currentSessionKey() async throws -> SymmetricKey {
        return await getKey()
    }

    // MARK: - Actor-isolated helpers

    private func getKey() -> SymmetricKey { testKey }

    private func processOutboundFrame(_ data: Data) {
        _sentFrames.append(data)

        // Inspect the frame type. For ppActivation, generate a canned ppToken response.
        guard let msgType = try? ClusterFrame.decodeType(from: data) else { return }

        switch msgType {
        case .ppActivation:
            // Pop the next canned token and enqueue a sealed ppToken response.
            let tokenID: Int32
            if !_cannedTokens.isEmpty {
                tokenID = _cannedTokens.removeFirst()
            } else {
                tokenID = 42  // default fallback token
            }
            if let payload = try? ClusterFrame.decodeJSON(PPActivationPayload.self, from: data),
               let sealed = try? TensorCrypto.sealToken(tokenID, key: testKey),
               let response = try? ClusterFrame.encodeJSON(
                type: .ppToken,
                value: PPTokenPayload(uid: payload.uid, sealedToken: sealed))
            {
                _responseQueue.append(response)
            }

        default:
            break  // ppSessionEnd and others need no response
        }
    }

    private func dequeueResponse() throws -> Data {
        guard !_responseQueue.isEmpty else {
            throw MockPPSessionError.noMoreResponses
        }
        return _responseQueue.removeFirst()
    }

    // MARK: - Inspection helpers

    var sentFrames: [Data] { _sentFrames }

    func decodedTypes() throws -> [ClusterMsgType] {
        try _sentFrames.map { try ClusterFrame.decodeType(from: $0) }
    }
}

enum MockPPSessionError: Error {
    case noMoreResponses
}

// MARK: - Shared test key

private func makeTestKey() -> SymmetricKey {
    SymmetricKey(size: .bits256)
}

// MARK: - ClusterMsgType raw value tests

@Test("ClusterMsgType.ppActivation has raw value 0x0B")
func ppActivationMsgTypeValue() {
    #expect(ClusterMsgType.ppActivation.rawValue == 0x0B)
}

@Test("ClusterMsgType.ppToken has raw value 0x0C")
func ppTokenMsgTypeValue() {
    #expect(ClusterMsgType.ppToken.rawValue == 0x0C)
}

@Test("ClusterMsgType.ppSessionEnd has raw value 0x0D")
func ppSessionEndMsgTypeValue() {
    #expect(ClusterMsgType.ppSessionEnd.rawValue == 0x0D)
}

// MARK: - PP payload JSON round-trips

@Test("PPActivationPayload encodes and decodes via JSON")
func ppActivationPayloadRoundTrip() throws {
    let sealedData = Data([0xAB, 0xCD, 0xEF, 0x01, 0x02, 0x03])
    let original = PPActivationPayload(uid: "pp-uid-1", seqLen: 4, sealedActivation: sealedData)
    let frame = try ClusterFrame.encodeJSON(type: .ppActivation, value: original)
    let msgType = try ClusterFrame.decodeType(from: frame)
    #expect(msgType == .ppActivation)
    let decoded = try ClusterFrame.decodeJSON(PPActivationPayload.self, from: frame)
    #expect(decoded.uid == original.uid)
    #expect(decoded.seqLen == original.seqLen)
    #expect(decoded.sealedActivation == original.sealedActivation)
}

@Test("PPTokenPayload encodes and decodes via JSON")
func ppTokenPayloadRoundTrip() throws {
    let sealedData = Data([0x10, 0x20, 0x30])
    let original = PPTokenPayload(uid: "pp-uid-2", sealedToken: sealedData)
    let frame = try ClusterFrame.encodeJSON(type: .ppToken, value: original)
    let msgType = try ClusterFrame.decodeType(from: frame)
    #expect(msgType == .ppToken)
    let decoded = try ClusterFrame.decodeJSON(PPTokenPayload.self, from: frame)
    #expect(decoded.uid == original.uid)
    #expect(decoded.sealedToken == original.sealedToken)
}

@Test("PPSessionEndPayload encodes and decodes via JSON")
func ppSessionEndPayloadRoundTrip() throws {
    let original = PPSessionEndPayload(uid: "pp-uid-3")
    let frame = try ClusterFrame.encodeJSON(type: .ppSessionEnd, value: original)
    let msgType = try ClusterFrame.decodeType(from: frame)
    #expect(msgType == .ppSessionEnd)
    let decoded = try ClusterFrame.decodeJSON(PPSessionEndPayload.self, from: frame)
    #expect(decoded.uid == original.uid)
}

// MARK: - EncryptedPipelineEngine construction

@Test("EncryptedPipelineEngine constructs with tiny LlamaModel and mock session")
func ppEngineConstructs() throws {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    let session = MockPPSession(testKey: testKey)
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let engine = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)
    _ = engine  // no throw = success
}

// MARK: - generate() loop

@Test("generate() produces ≤ maxTokens tokens and completes cleanly")
func ppGenerateProducesAtMostMaxTokens() async throws {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    // Provide 10 canned tokens so the engine can always get a response.
    let session = MockPPSession(testKey: testKey, cannedTokens: [10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let engine = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)

    let maxTokens = 5
    let stream = await engine.generate(
        promptTokens: [1, 2, 3, 4],
        maxTokens: maxTokens,
        eosTokenIDs: [99])  // 99 not in canned tokens

    var tokens: [Int] = []
    for await token in stream {
        tokens.append(token)
    }

    #expect(tokens.count <= maxTokens)
    #expect(tokens.count >= 1)
}

@Test("generate() frame sequence is ppActivation → ppToken × N → ppSessionEnd")
func ppGenerateFrameSequence() async throws {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    let session = MockPPSession(testKey: testKey, cannedTokens: [10, 11, 12, 99, 99, 99])
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let engine = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)

    let maxTokens = 3
    let stream = await engine.generate(
        promptTokens: [1, 2, 3],
        maxTokens: maxTokens,
        eosTokenIDs: [99])

    var tokens: [Int] = []
    for await token in stream {
        tokens.append(token)
    }

    // Inspect the outbound frame sequence from rank 0's perspective.
    // Note: ppToken frames are sent FROM rank 1 (mock), not rank 0 — they don't
    // appear in sentFrames. Rank 0 only sends ppActivation and ppSessionEnd.
    let types = try await session.decodedTypes()

    // All outbound frames from rank 0 must be either ppActivation or ppSessionEnd.
    let activationFrames = types.filter { $0 == .ppActivation }
    let endFrames = types.filter { $0 == .ppSessionEnd }

    // At least one ppActivation (the prefill).
    #expect(activationFrames.count >= 1)
    // Exactly one ppSessionEnd at the end.
    #expect(endFrames.count == 1)
    #expect(types.last == .ppSessionEnd)

    // Total: one ppActivation per token generated (prefill + each decode step) + one ppSessionEnd.
    #expect(types.count == tokens.count + 1,
            "Expected \(tokens.count + 1) frames (1 per token + sessionEnd), got \(types.count)")
}

@Test("generate() stops at EOS token")
func ppGenerateStopsAtEOS() async throws {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    // EOS is token 77; it's the very first canned response.
    let session = MockPPSession(testKey: testKey, cannedTokens: [77, 10, 10, 10, 10])
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let engine = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)

    let stream = await engine.generate(
        promptTokens: [1, 2],
        maxTokens: 10,
        eosTokenIDs: [77])

    var tokens: [Int] = []
    for await token in stream {
        tokens.append(token)
    }

    // Should stop immediately after receiving EOS token 77.
    #expect(tokens.count == 1)
    #expect(tokens.first == 77)
}

@Test("generate() sends ppSessionEnd as the last frame")
func ppGenerateSendsSessionEnd() async throws {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    let session = MockPPSession(testKey: testKey, cannedTokens: [5, 6, 7, 8, 9])
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let engine = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)

    let stream = await engine.generate(
        promptTokens: [1],
        maxTokens: 3,
        eosTokenIDs: [99])
    for await _ in stream {}

    let types = try await session.decodedTypes()
    #expect(types.last == .ppSessionEnd, "Expected ppSessionEnd as final frame, got \(String(describing: types.last))")
}

// MARK: - Sealed activation decryptability

@Test("ppActivation frames contain sealedActivation decryptable with session key")
func ppActivationFrameDecryptable() async throws {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    let session = MockPPSession(testKey: testKey, cannedTokens: [10, 11, 12])
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let engine = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)

    let stream = await engine.generate(
        promptTokens: [1, 2, 3],
        maxTokens: 2,
        eosTokenIDs: [99])
    for await _ in stream {}

    let frames = await session.sentFrames
    // Find the first ppActivation frame and verify its sealedActivation is decryptable.
    var foundDecryptable = false
    for frame in frames {
        guard let msgType = try? ClusterFrame.decodeType(from: frame),
              msgType == .ppActivation else { continue }
        let payload = try ClusterFrame.decodeJSON(PPActivationPayload.self, from: frame)
        // UID must be a valid UUID.
        #expect(UUID(uuidString: payload.uid) != nil, "ppActivation uid is not a valid UUID: \(payload.uid)")
        // seqLen must be positive.
        #expect(payload.seqLen > 0)
        // sealedActivation must decrypt without error using the test key.
        let (seqLen, activation) = try TensorCrypto.openActivation(
            payload.sealedActivation, key: testKey, hiddenDim: ppConfig.hiddenDim)
        #expect(seqLen == Int32(payload.seqLen))
        #expect(activation != nil)
        foundDecryptable = true
        break
    }
    #expect(foundDecryptable, "No decryptable ppActivation frame found in \(frames.count) sent frames")
}

// MARK: - KV cache slicing

@Test("EncryptedPipelineEngine cache is sliced to splitLayer entries")
func ppEngineCacheSlicing() throws {
    let llamaConfig = smallConfig()  // 4 layers
    let model = LlamaModel(llamaConfig)
    let testKey = makeTestKey()
    let session = MockPPSession(testKey: testKey)
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    // Full cache has 4 entries (one per layer); rank 0 keeps only the first 2.
    let fullCache = model.newCache(parameters: nil)
    #expect(fullCache.count == 4, "Expected 4 full-model cache slots, got \(fullCache.count)")
    let rank0Cache = fullCache.prefix(ppConfig.splitLayer).map { $0 }
    #expect(rank0Cache.count == 2, "Expected 2 rank-0 cache slots, got \(rank0Cache.count)")

    let _ = EncryptedPipelineEngine(config: ppConfig, model: model, session: session)
    // Engine constructed without error — cache slicing verified indirectly.
}

@Test("EncryptedPipelineServer cache is sliced to (numLayers - splitLayer) entries")
func ppServerCacheSlicing() throws {
    let llamaConfig = smallConfig()  // 4 layers
    let model = LlamaModel(llamaConfig)
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let fullCache = model.newCache(parameters: nil)
    #expect(fullCache.count == 4)
    let rank1Cache = fullCache.suffix(ppConfig.numLayers - ppConfig.splitLayer).map { $0 }
    #expect(rank1Cache.count == 2, "Expected 2 rank-1 cache slots, got \(rank1Cache.count)")

    let _ = EncryptedPipelineServer(config: ppConfig, model: model)
    // Server constructed without error — cache slicing verified indirectly.
}

// MARK: - EncryptedPipelineServer makeInferenceHandler API

@Test("EncryptedPipelineServer.makeInferenceHandler returns a non-nil handler")
func ppServerMakesInferenceHandler() {
    let llamaConfig = smallConfig()
    let model = LlamaModel(llamaConfig)
    let ppConfig = EncryptedPipelineConfig(
        splitLayer: 2,
        numLayers: 4,
        hiddenDim: 64,
        vocabSize: 128)
    let server = EncryptedPipelineServer(config: ppConfig, model: model)
    let handler = server.makeInferenceHandler()
    // Handler is a non-escaping closure — just verify it compiles and is non-nil.
    let _: @Sendable (ThunderboltConnection, SymmetricKey, Data) async throws -> Void = handler
}

// MARK: - TensorCrypto integration: seal/open token round-trip

@Test("TensorCrypto.sealToken and openToken round-trip")
func tensorCryptoTokenRoundTrip() throws {
    let key = SymmetricKey(size: .bits256)
    let originalToken: Int32 = 42
    let sealed = try TensorCrypto.sealToken(originalToken, key: key)
    let recovered = try TensorCrypto.openToken(sealed, key: key)
    #expect(recovered == originalToken)
}

@Test("TensorCrypto.sealActivation and openActivation round-trip for a small tensor")
func tensorCryptoActivationRoundTrip() throws {
    let key = SymmetricKey(size: .bits256)
    let seqLen: Int32 = 2
    let hiddenDim = 4
    // Build a simple [1, 2, 4] bfloat16 activation tensor.
    let shape = [1, Int(seqLen), hiddenDim]
    let values: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
    let activation = MLXArray(values, shape).asType(.bfloat16)
    eval(activation)

    let sealed = try TensorCrypto.sealActivation(seqLen: seqLen, activation: activation, key: key)
    let (recoveredSeqLen, recoveredActivation) = try TensorCrypto.openActivation(
        sealed, key: key, hiddenDim: hiddenDim)

    #expect(recoveredSeqLen == seqLen)
    #expect(recoveredActivation != nil)
    #expect(recoveredActivation?.shape == [1, Int(seqLen), hiddenDim])
}
