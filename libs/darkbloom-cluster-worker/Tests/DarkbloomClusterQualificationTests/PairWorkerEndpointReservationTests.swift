import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterQualification

/// The endpoint moves a reservation's deadline onto its worker's launch clock
/// and must hand over everything else as it was given. The "worker" is
/// `/bin/sh`: it prints the launch line and copies its input to a file, so the
/// test reads back exactly the frames the endpoint wrote.
final class PairWorkerEndpointReservationTests: XCTestCase {
    private static let hash = String(repeating: "a", count: 64)
    /// The launch line's worker clock reading.
    private static let workerUptime: UInt64 = 1_000_000_000

    func testEveryReservationFieldReachesTheWorkerWithOnlyItsDeadlineTranslated() throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("pair-endpoint-reservation-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: capture) }
        let script = "printf 'darkbloom-pair-launch-v1 pid=%s uptime=\(Self.workerUptime) deadline=\(2 * Self.workerUptime)\\n' "
            + "\"$$\" >&2; exec /bin/cat > \"$1\""
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(), modelID: "example-model",
            artifactSHA256: Self.hash, configurationSHA256: Self.hash,
            peers: [.init(id: "first", buildSHA256: Self.hash), .init(id: "second", buildSHA256: Self.hash)])
        let profile = ClusterWorkerProfile(id: "example-profile", vocabularySize: 262_144, maximumPromptTokens: 16,
            maximumOutputTokens: 8, maximumChunkTokens: 8, maximumContextTokens: 24)
        let endpoint = try PairWorkerEndpoint(command: ["/bin/sh", "-c", script, "sh", capture.path],
            expectedIdentity: identity, rank: 0, profile: profile, executionPlanSHA256: Self.hash)
        let launched = DispatchTime.now().uptimeNanoseconds
        try endpoint.launch()
        XCTAssertTrue(endpoint.waitForLaunchLine(until: launched + 10_000_000_000))
        let lineRead = DispatchTime.now().uptimeNanoseconds

        let sent = Self.oneReservationPerCarrier(deadline: lineRead + 60_000_000_000)
        // Together the fixtures set every optional field.
        XCTAssertTrue(sent.contains { $0.sampling != nil } && sent.contains { $0.prefixCache != nil } && sent.contains { $0.route != nil }
            && sent.contains { $0.mimoImages != nil } && sent.contains { $0.stillImages != nil }
            && sent.contains { $0.glmMedia != nil } && sent.contains { $0.qwenMedia != nil })
        for reservation in sent {
            try endpoint.sendWorkerCommand(.reserve(reservation), requestID: UUID(),
                deadline: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
        }
        endpoint.requestNativeCleanup()
        XCTAssertTrue(endpoint.waitForExit(until: DispatchTime.now().uptimeNanoseconds + 10_000_000_000))

        let received = try Self.reservations(in: Data(contentsOf: capture))
        XCTAssertEqual(received.count, sent.count)
        for (given, delivered) in zip(sent, received) {
            XCTAssertEqual(delivered.sampling, given.sampling)
            XCTAssertEqual(delivered.prefixCache, given.prefixCache)
            XCTAssertEqual(delivered.route, given.route)
            XCTAssertEqual(delivered.mimoImages, given.mimoImages)
            XCTAssertEqual(delivered.stillImages, given.stillImages)
            XCTAssertEqual(delivered.glmMedia, given.glmMedia)
            XCTAssertEqual(delivered.qwenMedia, given.qwenMedia)
            XCTAssertEqual(delivered, given.withDeadline(delivered.deadlineUptimeNanoseconds))
            // The worker clock read `workerUptime` when this Mac's clock read
            // somewhere between the launch and the line being seen.
            let earliest = given.deadlineUptimeNanoseconds + Self.workerUptime - lineRead
            let latest = given.deadlineUptimeNanoseconds + Self.workerUptime - launched
            XCTAssertTrue((earliest...latest).contains(delivered.deadlineUptimeNanoseconds))
        }
    }

    /// The reserve commands in a captured command stream, in order.
    private static func reservations(in stream: Data) throws -> [ClusterWorkerReservation] {
        var decoder = ClusterWorkerLineDecoder(commandStream: true)
        var lines: [Data] = []
        var offset = stream.startIndex
        while offset < stream.endIndex {
            let end = min(offset + ClusterWorkerLineDecoder.readChunkBytes, stream.endIndex)
            lines += try decoder.append(stream[offset..<end])
            offset = end
        }
        try decoder.finish()
        return try lines.compactMap { line in
            guard case .command(let frame) = try ClusterWorkerCodec.decodeControl(line),
                  case .reserve(let reservation) = frame.command else { return nil }
            return reservation
        }
    }

    /// One reservation per media carrier, since the protocol lets a request
    /// carry one, each with every other field its carrier allows: sampling and
    /// a prefix partition on all of them (a tenant's on text, the cache off
    /// with media), the route only without media.
    private static func oneReservationPerCarrier(deadline: UInt64) -> [ClusterWorkerReservation] {
        let sampling = ClusterWorkerSampling(temperature: 0.7, topP: 0.9, topK: 20, minP: 0.05, repetitionPenalty: 1.1,
            repetitionContextSize: 64, frequencyPenalty: 0, presencePenalty: 0.5, seed: 41, stream: 7,
            logitBias: [.init(tokenID: 3, bias: -2)], topLogprobs: 2)
        func reservation(_ profileID: String, _ prompt: [Int], prefixCache: ClusterWorkerPrefixCache = .disabled,
                         route: ClusterWorkerRoute? = nil,
                         mimoImages: ClusterMiMoImages? = nil, stillImages: ClusterStillImages? = nil,
                         glmMedia: ClusterGLMMedia? = nil, qwenMedia: ClusterQwenMedia? = nil) -> ClusterWorkerReservation {
            .init(profileID: profileID, promptTokenIDs: prompt, stopTokenIDs: [2, 9], outputCount: 4, chunkSize: 2,
                deadlineUptimeNanoseconds: deadline, capacityLimitBytes: 1 << 20, sampling: sampling, prefixCache: prefixCache,
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
