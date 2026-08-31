import CryptoKit
import Foundation
import InferenceWorkerProtocol
@testable import ProviderCore
@testable import InferenceWorkerCore
import Testing

private final class RecordingWorkerHost: NSObject, InferenceWorkerHostProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [WorkerResponseFrame] = []
    private var storedEvents: [WorkerEvent] = []

    func workerDidEmit(_ frame: WorkerResponseFrame) {
        lock.lock(); storedFrames.append(frame); lock.unlock()
    }

    func workerDidEmitEvent(_ event: WorkerEvent) {
        lock.lock(); storedEvents.append(event); lock.unlock()
    }

    var frames: [WorkerResponseFrame] {
        lock.lock(); defer { lock.unlock() }; return storedFrames
    }
}
private final class TestCodeChallengeSigner: AttestationSigner, @unchecked Sendable {
    private let key = P256.Signing.PrivateKey()
    var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
    func sign(_ data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}
private final class PrivateChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PrivateV2Chunk] = []

    func append(_ chunk: PrivateV2Chunk) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    var chunks: [PrivateV2Chunk] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
private final class UniqueNonceGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0

    func next() -> Data {
        lock.lock()
        defer { lock.unlock() }
        var value = counter.bigEndian
        counter &+= 1
        var nonce = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: &value) { nonce.append(contentsOf: $0) }
        return nonce
    }
}


@Suite("Inference worker service")
struct InferenceWorkerServiceTests {
    @Test func launchKeyRotatesAndPrivateKeyNeverLeavesRuntime() {
        let first = InferenceWorkerRuntime()
        let second = InferenceWorkerRuntime()
        #expect(first.processPublicKey.count == 32)
        #expect(second.processPublicKey.count == 32)
        #expect(first.processPublicKey != second.processPublicKey)
        #expect(first.launchID != second.launchID)
    }

    @Test func sameCatalogCanAdvanceModelGenerationAtomically() async throws {
        let runtime = InferenceWorkerRuntime()
        let first = try #require(WorkerBootstrapConfiguration(
            modelCatalogJSON: Data("[]".utf8),
            artifacts: [],
            releaseBinaryHash: String(repeating: "a", count: 64),
            releaseGeneration: 1,
            modelGeneration: 1,
            privateCacheLimitBytes: 1024 * 1024))
        let second = try #require(WorkerBootstrapConfiguration(
            modelCatalogJSON: first.modelCatalogJSON,
            inferenceConfigurationJSON: first.inferenceConfigurationJSON,
            artifacts: [],
            releaseBinaryHash: String(repeating: "a", count: 64),
            releaseGeneration: 1,
            modelGeneration: 2,
            privateCacheLimitBytes: 1024 * 1024))
        #expect(try await runtime.configure(first).acceptedModelIdentifiers.isEmpty)
        #expect(try await runtime.configure(second).acceptedModelIdentifiers.isEmpty)
    }

    @Test func encryptedChallengeIsDomainBoundAndReturnsTypedProof() async throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_SIGNED_HOST_TEST"] == "1" else {
            return
        }
        let signer = TestCodeChallengeSigner()
        let runtime = InferenceWorkerRuntime(attestationSigner: signer)
        let service = InferenceWorkerService(runtime: runtime)
        let host = RecordingWorkerHost()
        service.attach(host: host)

        let configuration = try #require(WorkerBootstrapConfiguration(
            modelCatalogJSON: Data("[]".utf8),
            artifacts: [],
            releaseBinaryHash: String(repeating: "0", count: 64),
            releaseGeneration: 1,
            modelGeneration: 1,
            privateCacheLimitBytes: 1024 * 1024))
        let configureResult: (WorkerBootstrapResult?, Int) =
            await withCheckedContinuation { continuation in
                service.configure(configuration) {
                    continuation.resume(returning: ($0, $1))
                }
            }
        #expect(configureResult.1 == InferenceWorkerErrorCode.none.rawValue)
        #expect(configureResult.0 != nil)

        let generation: UInt64 = 7
        let certifyCode: Int = await withCheckedContinuation { continuation in
            service.certify(
                launchIdentifier: runtime.launchID,
                connectionGeneration: generation) {
                    continuation.resume(returning: $0)
                }
        }
        #expect(certifyCode == InferenceWorkerErrorCode.none.rawValue)
        let nonce = Data(repeating: 0xA7, count: 32).base64EncodedString()
        let consumer = NodeKeyPair.generate()
        let ciphertext = try consumer.encrypt(
            recipientPublicKey: runtime.processPublicKey,
            plaintext: Data(nonce.utf8))
        let request = try #require(WorkerCodeChallengeRequest(
            launchIdentifier: runtime.launchID,
            connectionGeneration: generation,
            senderPublicKey: consumer.publicKeyBytes,
            ciphertext: ciphertext))
        let result: (WorkerCodeChallengeProof?, Int) = await withCheckedContinuation {
            continuation in
            service.answerCodeChallenge(request) {
                continuation.resume(returning: ($0, $1))
            }
        }
        #expect(result.1 == InferenceWorkerErrorCode.none.rawValue)
        let proof = try #require(result.0)
        #expect(proof.nonce == nonce)
        #expect(proof.launchIdentifier == runtime.launchID)
        #expect(proof.connectionGeneration == generation)
        #expect(proof.bindingDigest.count == 64)
        let replayCode: Int = await withCheckedContinuation { continuation in
            service.answerCodeChallenge(request) { _, code in
                continuation.resume(returning: code)
            }
        }
        #expect(replayCode == InferenceWorkerErrorCode.invalidRequest.rawValue)
    }

    @Test func brokerRejectsSymlinkEscape() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let approved = base.appendingPathComponent("approved", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let link = approved.appendingPathComponent("escaped", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let broker = try ModelArtifactBroker(approvedRoots: [approved])
        #expect(throws: ModelArtifactBrokerError.symbolicLink) {
            try broker.descriptor(
                modelIdentifier: "org/model",
                snapshotURL: link,
                expectedManifestSHA256: String(repeating: "0", count: 64))
        }
    }

    @Test func sandboxSelfTestOutputSurvivesImmediateExitThroughPipe() throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/darkbloom-inference-worker")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--sandbox-self-test-v1"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["DARKBLOOM_SIGNED_HOST_TEST": "1"],
            uniquingKeysWith: { _, testValue in testValue })
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let line = try #require(String(data: output, encoding: .utf8))
        #expect(line.hasPrefix("DBXPC_SANDBOX_SELF_TEST_V1:"))
        #expect(line.hasSuffix("\n"))
    }

    @Test func privateWriterSupportsFull8192ChunkProtocolRange() throws {
        let recorder = PrivateChunkRecorder()
        let nonceGenerator = UniqueNonceGenerator()
        let writer = PrivateV2ChunkWriter(
            requestId: "full-range",
            transcriptDigest: Data(repeating: 7, count: 32),
            responseKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            nonceGenerator: nonceGenerator.next,
            sink: recorder.append)
        let payload = Data("{}".utf8)
        for _ in 0..<(PrivateV2Protocol.maximumChunksPerRequest - 1) {
            try writer.emit(payload: payload, terminal: false)
        }
        try writer.emit(payload: payload, terminal: true)

        let chunks = recorder.chunks
        #expect(chunks.count == Int(PrivateV2Protocol.maximumChunksPerRequest))
        #expect(chunks.first?.sequence == 0)
        #expect(chunks.last?.sequence == 8_191)
        #expect(chunks.last?.terminal == true)
    }

    @Test func terminalMetadataCarriesValueOnlyPrefixV2Evidence() throws {
        let anchor = PrefixCacheAnchor(
            chainHash: String(repeating: "a", count: 64),
            tokenCount: 64)
        let lookup = WorkerPrefixLookupV2Metadata(
            requestId: "receipt-request",
            cacheReceiptNonce: "receipt-nonce",
            modelId: "org/model",
            modelAggregateHash: String(repeating: "b", count: 64),
            promptContractId: "contract",
            cacheEpoch: "epoch",
            cacheSeq: 9,
            promptAnchor: anchor,
            matchedAnchor: nil,
            outcome: .missAbsent,
            tier: .ssd,
            requiredRecomputeTokens: 0,
            expectedPrefillTokensSaved: 0,
            stageMs: 1.5)
        let metadata = WorkerTerminalMetadata(
            cacheReceiptNonce: "receipt-nonce",
            prefixCacheProtocol: 2,
            lookup: nil,
            ready: nil,
            lookupV2: lookup,
            readyV2: nil,
            stopSequence: nil,
            reasoningTokens: 3)
        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(
            WorkerTerminalMetadata.self, from: encoded)
        #expect(decoded.lookupV2?.cacheSeq == 9)
        #expect(decoded.lookupV2?.providerMessage.cacheSeq == 9)
        #expect(decoded.reasoningTokens == 3)
    }
}
