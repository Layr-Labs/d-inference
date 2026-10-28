import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import DarkbloomClusterRemote

/// The owner wire and the peer link re-time a reservation for the receiving
/// Mac's clock. Each must deliver every other field as sent.
struct ClusterReservationRelayTests {
    private static let hash = String(repeating: "a", count: 64)

    @Test func ownerAndLinkHopsChangeOnlyTheDeadline() throws {
        let epoch = UUID(), request = UUID(), session = UUID()
        let sent = Self.oneReservationPerCarrier()
        #expect(sent.contains { $0.sampling != nil } && sent.contains { $0.prefixCache != nil } && sent.contains { $0.route != nil }
            && sent.contains { $0.mimoImages != nil } && sent.contains { $0.stillImages != nil }
            && sent.contains { $0.glmMedia != nil } && sent.contains { $0.qwenMedia != nil })
        for reservation in sent {
            let expected = ClusterWorkerCommand.reserve(reservation.withDeadline(1000))
            let frame = ClusterWorkerCommandFrame(membershipEpoch: epoch, sequence: 2,
                requestID: request, command: .reserve(reservation))
            let owner = try OwnerWire.command(frame, lease: UUID(), incarnation: UUID(), sequence: 3,
                now: 100, deliveryDeadline: 500)
            let ownerLocal = try OwnerWire.decode(owner.encoded(commandStream: true), commandStream: true)
                .localCommand(now: 200, lifetimeDeadline: 1500)
            #expect(ownerLocal.command == expected)
            let link = try ClusterLinkWorkerWire.command(.reserve(reservation), requestID: request,
                epoch: epoch, session: session, sequence: 4, now: 100, deliveryDeadline: 500)
            #expect(try link.localCommand(now: 200).command == expected)
        }
    }

    /// One reservation per media carrier, since the protocol lets a request
    /// carry one, each with every other field its carrier allows: a tenant's
    /// prefix partition on text, the cache off with media.
    private static func oneReservationPerCarrier() -> [ClusterWorkerReservation] {
        let sampling = ClusterWorkerSampling(temperature: 0.7, topP: 0.9, topK: 20, minP: 0.05, repetitionPenalty: 1.1,
            repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0.5, seed: 41, stream: 7,
            logitBias: [.init(tokenID: 3, bias: -2)], topLogprobs: 2)
        func reservation(_ profileID: String, _ prompt: [Int], prefixCache: ClusterWorkerPrefixCache = .disabled,
                         route: ClusterWorkerRoute? = nil,
                         mimoImages: ClusterMiMoImages? = nil, stillImages: ClusterStillImages? = nil,
                         glmMedia: ClusterGLMMedia? = nil, qwenMedia: ClusterQwenMedia? = nil) -> ClusterWorkerReservation {
            .init(profileID: profileID, promptTokenIDs: prompt, stopTokenIDs: [2, 9], outputCount: 4, chunkSize: 2,
                deadlineUptimeNanoseconds: 900, capacityLimitBytes: 1 << 20, sampling: sampling, prefixCache: prefixCache,
                route: route, mimoImages: mimoImages, stillImages: stillImages, glmMedia: glmMedia, qwenMedia: qwenMedia)
        }
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: 7, count: 40)
        let bytes = Data([1, 2, 3])
        let glm = ClusterGLMMedia(configurationSHA256: hash,
            processor: .init(patchSize: 14, imageMinimumTokens: 1, imageMaximumTokens: 16,
                videoMinimumTokens: 1, videoMaximumTokens: 16),
            items: [.init(kind: .image, sha256: hash, byteCount: bytes.count, encoded: bytes, temporal: 1,
                height: 2, width: 2, maximumPatches: 4, maximumQueryTokens: 4, maximumScoreElements: 16,
                patchesSHA256: hash, tokenOffsets: [1])])
        let qwen = ClusterQwenMedia(artifactSHA256: hash, configurationSHA256: hash, processorSHA256: hash,
            processorPolicy: .qwen35, promptLength: 3, promptSHA256: ClusterQwenMedia.int32SHA256([1, 2, 3]),
            positionIDsSHA256: hash, decodeDeltas: [-1],
            items: [.init(kind: .image, sha256: ClusterQwenMedia.sha256(bytes), byteCount: bytes.count,
                decodedPixels: 1, encoded: bytes, temporal: 1, height: 2, width: 2, tokenOffset: 1, tokenCount: 1,
                patchesSHA256: hash)])
        return [
            reservation("example-profile", [1, 2, 3, 4], prefixCache: .tenant(hash), route: .decodingRankAlone),
            reservation(ClusterStillImages.glmProfileID, [1, 2, 3, 4], stillImages: .init(configurationSHA256: hash,
                images: [.init(png: png, width: 2, height: 2, tokenOffset: 1, tokenCount: 1)])),
            reservation(ClusterMiMoImageCandidate.profileID, [1, 151_652, 151_655, 151_653, 2],
                mimoImages: .init(images: [.init(png: png, width: 2, height: 2, tokenOffset: 2, tokenCount: 1)])),
            reservation(ClusterGLMImageCandidate.textProfileID, [1, 2, 3, 4], glmMedia: glm),
            reservation("example-profile", [1, 2, 3], qwenMedia: qwen),
        ]
    }
}
