import Foundation
import InferenceWorkerCore
import InferenceWorkerProtocol
import ProviderCore
import Testing

@Suite("Inference worker contract")
struct InferenceWorkerContractTests {
    @Test func secureCodingRoundTripAndBounds() throws {
        let payload = Data(repeating: 0xA5, count: 1024)
        let sender = Data(repeating: 0x11, count: 32)
        let request = try #require(WorkerInferenceRequest(
            kind: .legacy,
            requestIdentifier: "request-1",
            envelope: payload,
            senderPublicKey: sender,
            authenticatedMetadataJSON: nil,
            firstContentDeadlineUptimeNanoseconds: 123_456_789))
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: request, requiringSecureCoding: true)
        let unarchived = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: WorkerInferenceRequest.self, from: archived)
        let decoded = try #require(unarchived)
        #expect(decoded.requestIdentifier == "request-1")
        #expect(decoded.envelope == payload)
        #expect(decoded.senderPublicKey == sender)
        #expect(decoded.firstContentDeadlineUptimeNanoseconds == 123_456_789)
        #expect(WorkerInferenceRequest(
            kind: .legacy,
            requestIdentifier: "too-large",
            envelope: Data(count: InferenceWorkerContract.maximumRequestBytes + 1),
            senderPublicKey: sender,
            authenticatedMetadataJSON: nil) == nil)
        #expect(WorkerInferenceRequest(
            kind: .legacy,
            requestIdentifier: "bad-key",
            envelope: payload,
            senderPublicKey: Data(count: 31),
            authenticatedMetadataJSON: nil) == nil)
    }

    @Test func frameAndAcknowledgementBoundsAreFixed() {
        #expect(InferenceWorkerContract.maximumConcurrentRequests == 64)
        #expect(InferenceWorkerContract.maximumFramesPerRequest == 8_194)
        #expect(InferenceWorkerContract.maximumPrivateV2Chunks == 8_192)
        #expect(InferenceWorkerContract.acknowledgementWindow == 8)
        #expect(WorkerResponseFrame(
            kind: .legacyEncryptedChunk,
            requestIdentifier: "r",
            sequence: 8_194,
            payload: Data(),
            terminal: false) == nil)
        #expect(WorkerFrameAcknowledgement(
            requestIdentifier: "r", sequence: 8_194) == nil)
        #expect(WorkerResponseFrame(
            kind: .privateV2EncryptedChunk,
            requestIdentifier: "r",
            sequence: 8_193,
            payload: Data(),
            terminal: true) != nil)
        #expect(WorkerFrameAcknowledgement(
            requestIdentifier: "r", sequence: 8_193) != nil)
        #expect(WorkerResponseFrame(
            kind: .terminal,
            requestIdentifier: "r",
            sequence: 0,
            terminal: false) == nil)
    }

    @Test func terminalProofAndBoundedMetadataRoundTrip() throws {
        let hash = String(repeating: "a", count: 64)
        let metadata = Data(#"{"stopSequence":"END"}"#.utf8)
        let frame = try #require(WorkerResponseFrame(
            kind: .terminal,
            requestIdentifier: "proof-request",
            sequence: 8_193,
            promptTokens: 9,
            completionTokens: 4,
            responseHash: hash,
            attestationSignature: "signed",
            resultMetadataJSON: metadata,
            terminal: true))
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: frame, requiringSecureCoding: true)
        let unarchived = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: WorkerResponseFrame.self, from: archived)
        let decoded = try #require(unarchived)
        #expect(decoded.responseHash == hash)
        #expect(decoded.attestationSignature == "signed")
        #expect(decoded.resultMetadataJSON == metadata)
        #expect(WorkerResponseFrame(
            kind: .terminal,
            requestIdentifier: "too-much-metadata",
            sequence: 0,
            resultMetadataJSON: Data(
                count: InferenceWorkerContract.maximumMetadataBytes + 1),
            terminal: true) == nil)
    }

    @Test func capacityPrefixAdvertisementIsSecureCodedAndBounded() throws {
        let metadata = Data(#"{"protocolVersion":2,"models":[],"statuses":[],"donationOutcomes":[]}"#.utf8)
        let snapshot = try #require(WorkerCapacitySnapshot(
            launchIdentifier: "launch",
            sequence: 7,
            entries: [],
            prefixCacheAdvertisementJSON: metadata))
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: snapshot, requiringSecureCoding: true)
        let unarchived = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: WorkerCapacitySnapshot.self, from: archived)
        let decoded = try #require(unarchived)
        #expect(decoded.prefixCacheAdvertisementJSON == metadata)
        #expect(WorkerCapacitySnapshot(
            launchIdentifier: "launch",
            sequence: 8,
            entries: [],
            prefixCacheAdvertisementJSON: Data(
                count: InferenceWorkerContract.maximumMetadataBytes + 1)) == nil)
    }
    @Test func bootstrapInferenceConfigurationIsSecureCodedAndBounded() throws {
        let inference = Data(#"{"maximumCachedModels":4}"#.utf8)
        let configuration = try #require(WorkerBootstrapConfiguration(
            modelCatalogJSON: Data("[]".utf8),
            inferenceConfigurationJSON: inference,
            artifacts: [],
            releaseBinaryHash: String(repeating: "0", count: 64),
            releaseGeneration: 1,
            modelGeneration: 2,
            privateCacheLimitBytes: 1))
        let archived = try NSKeyedArchiver.archivedData(
            withRootObject: configuration, requiringSecureCoding: true)
        let unarchived = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: WorkerBootstrapConfiguration.self, from: archived)
        #expect(try #require(unarchived).inferenceConfigurationJSON == inference)
        #expect(WorkerBootstrapConfiguration(
            modelCatalogJSON: Data("[]".utf8),
            inferenceConfigurationJSON: Data(
                count: InferenceWorkerContract.maximumMetadataBytes + 1),
            artifacts: [],
            releaseBinaryHash: String(repeating: "0", count: 64),
            releaseGeneration: 1,
            modelGeneration: 2,
            privateCacheLimitBytes: 1) == nil)
    }


    @Test func releaseFixtureContractCannotSkip() {
        #expect(InferenceWorkerContract.machServiceName == "io.darkbloom.provider.inference-worker")
        #expect(InferenceWorkerContract.workerBundleIdentifier == "io.darkbloom.provider.inference-worker")
        #expect(InferenceWorkerContract.hostBundleIdentifier == "io.darkbloom.provider")
        #expect(InferenceWorkerContract.teamIdentifier == "SLDQ2GJ6TL")
        #expect(InferenceWorkerContract.hostDesignatedRequirement ==
            "anchor apple generic and identifier \"io.darkbloom.provider\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\"")
        #expect(InferenceWorkerContract.workerDesignatedRequirement ==
            "anchor apple generic and identifier \"io.darkbloom.provider.inference-worker\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\"")
        #expect(InferenceWorkerContract.relativeExecutablePath.hasSuffix(
            "/darkbloom-inference-worker"))
    }

    @Test func privateCacheRejectsTraversalAndEnforcesCapacity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try WorkerPrivateCache(root: root, maximumBytes: 8)
        try cache.write(name: "cache.bin", data: Data([1, 2, 3, 4]))
        #expect(try cache.read(name: "cache.bin", maximumBytes: 8) == Data([1, 2, 3, 4]))
        #expect(throws: WorkerPrivateCacheError.invalidName) {
            try cache.write(name: "../escape", data: Data())
        }
        #expect(throws: WorkerPrivateCacheError.capacityExceeded) {
            try cache.write(name: "other.bin", data: Data(count: 5))
        }
    }

    @Test func signedHostSandboxProbe() {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_SIGNED_HOST_TEST"] == "1" else {
            return
        }
        #expect(WorkerSandboxSelfTest.run() == 63)
    }
}
