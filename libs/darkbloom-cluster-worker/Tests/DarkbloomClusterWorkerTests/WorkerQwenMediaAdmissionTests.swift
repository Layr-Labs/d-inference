import DarkbloomClusterProtocol
import Foundation
import Testing
@testable import DarkbloomClusterWorker

struct WorkerQwenMediaAdmissionTests {
    private let a = String(repeating: "a", count: 64)
    private let b = String(repeating: "b", count: 64)
    private func media() -> ClusterQwenMedia {
        let bytes = Data([7])
        return .init(artifactSHA256: a, configurationSHA256: b, processorSHA256: a,
            processorPolicy: .qwen35, promptLength: 3,
            promptSHA256: ClusterQwenMedia.int32SHA256([1, 2, 3]), positionIDsSHA256: b,
            decodeDeltas: [0], items: [.init(kind: .image,
                sha256: ClusterQwenMedia.sha256(bytes), byteCount: 1, decodedPixels: 1024,
                encoded: bytes, temporal: 1, height: 2, width: 2,
                tokenOffset: 1, tokenCount: 1, patchesSHA256: a)])
    }
    private func reservation(_ media: ClusterQwenMedia?, profile: String = "profile",
                             route: ClusterWorkerRoute? = nil) -> ClusterWorkerReservation {
        .init(profileID: profile, promptTokenIDs: [1, 2, 3], stopTokenIDs: [], outputCount: 1,
              chunkSize: 3, deadlineUptimeNanoseconds: 100, capacityLimitBytes: 4096,
              sampling: nil, prefixCache: nil, route: route, qwenMedia: media)
    }
    private func ready(rank: Int = 0, contract: String? = ClusterQwenMedia.contract,
                       protection: String = ClusterWorkerDataPlane.encrypted,
                       verified: Bool = true, artifact: String? = nil,
                       configuration: String? = nil, profile: String = "profile") -> ClusterWorkerReady {
        .init(identity: .init(membershipEpoch: UUID(), modelID: "registered_qwen38_27b",
            artifactSHA256: artifact ?? a, configurationSHA256: configuration ?? b, peers: []),
            rank: rank, profile: .init(id: profile, vocabularySize: 64,
                maximumPromptTokens: 128, maximumOutputTokens: 128,
                maximumChunkTokens: 128, maximumContextTokens: 256),
            executionPlanSHA256: a, requestCapacityBytes: 4096,
            dataPlane: .init(protection: protection, peerVerified: verified,
                             transcriptSHA256: a, edgeID: "edge"), media: contract)
    }
    @Test func exactLoadedContractAndRankOwnershipAreRequired() {
        let value = media()
        #expect(WorkerQwenMediaAdmission.accepts(reservation(value), ready: ready()))
        #expect(WorkerQwenMediaAdmission.accepts(reservation(value.withoutEncodedBytes), ready: ready(rank: 1)))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(value.withoutEncodedBytes), ready: ready()))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(value), ready: ready(rank: 1)))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(value), ready: ready(rank: 2)))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(value), ready: nil))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(value), ready: ready(contract: nil)))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(value), ready: ready(contract: ClusterGLMMedia.contract)))
    }
    @Test func downgradeAndDifferentSourceRefuseBeforeOwnerAdmission() {
        let value = reservation(media())
        #expect(!WorkerQwenMediaAdmission.accepts(value, ready: ready(protection: "plaintext")))
        #expect(!WorkerQwenMediaAdmission.accepts(value, ready: ready(verified: false)))
        #expect(!WorkerQwenMediaAdmission.accepts(value, ready: ready(artifact: b)))
        #expect(!WorkerQwenMediaAdmission.accepts(value, ready: ready(configuration: a)))
        #expect(!WorkerQwenMediaAdmission.accepts(value, ready: ready(profile: "foreign")))
        #expect(!WorkerQwenMediaAdmission.accepts(reservation(media(), route: .decodingRankAlone), ready: ready()))
    }
    @Test func absentCarrierPreservesEveryExistingOwnerPath() {
        let value = reservation(nil)
        #expect(WorkerQwenMediaAdmission.accepts(value, ready: nil))
        #expect(WorkerQwenMediaAdmission.accepts(value, ready: ready(contract: nil, verified: false)))
        #expect(WorkerQwenMediaAdmission.accepts(value, ready: ready(contract: ClusterGLMMedia.contract)))
    }
}
