import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLLM
import Testing
@testable import DarkbloomClusterRuntime

/// The model-free parts of GLM images and video on the tensor-parallel pair:
/// the envelope bound to its prompt, its wire through the worker codec (bytes
/// to rank 0 only), the record framing that carries it, the exact feature
/// crossing, the splice, the request charge, rank 0's preparation off the
/// executor and the status rounds both ranks open with. The tower, the processor and
/// the pair need the model (`agent-work/vision/NOTES.md`, test plan).
@Suite("GLM tensor-parallel media")
struct GLM5NextTensorParallelMediaTests {
    // The fixture configuration's markers (`GLM5NextMetadataTestFixture`).
    static let image = 10, video = 11, begin = 12, end = 13, videoBegin = 14, videoEnd = 15

    /// `[text, image(4 tokens), text, video pair 0, timestamp, video pair 1, timestamp, text]`.
    static func prompt() -> (tokens: [Int], imageOffset: Int, pairOffsets: [Int]) {
        var t = [3, 4, begin], offsets: [Int] = []
        let imageOffset = t.count
        t += Array(repeating: image, count: 4) + [end, 5, videoBegin]
        for _ in 0 ..< 2 {
            t.append(begin); offsets.append(t.count)
            t += Array(repeating: image, count: 4) + [end, 6, 7]
        }
        t += [videoEnd, 8]
        return (t, imageOffset, offsets)
    }

    static let digest = String(repeating: "ab", count: 32)
    static func item(_ kind: ClusterGLMMedia.Kind, _ offsets: [Int], bytes: Data? = Data(repeating: 7, count: 40))
        -> ClusterGLMMedia.Item {
        .init(kind: kind, sha256: ClusterGLMMedia.sha256(bytes ?? Data(repeating: 7, count: 40)), byteCount: 40,
            encoded: bytes, temporal: offsets.count, height: 4, width: 4, maximumPatches: 32_000,
            maximumQueryTokens: 16, maximumScoreElements: 32_000_000, patchesSHA256: digest, tokenOffsets: offsets)
    }
    static let processor = ClusterGLMMedia.Processor(patchSize: 2, imageMinimumTokens: 16, imageMaximumTokens: 8000,
        videoMinimumTokens: 16, videoMaximumTokens: 240_000)
    static func media(_ items: [ClusterGLMMedia.Item]) -> ClusterGLMMedia {
        .init(configurationSHA256: digest, processor: processor, items: items)
    }
    static func validate(_ media: ClusterGLMMedia, _ tokens: [Int]) throws {
        try media.validate(prompt: tokens, imageToken: image, startToken: begin, endToken: end, videoToken: video)
    }

    @Test func spansBindEveryMediaMarkerOfThePrompt() throws {
        let p = Self.prompt()
        let good = Self.media([Self.item(.image, [p.imageOffset]), Self.item(.video, p.pairOffsets)])
        try Self.validate(good, p.tokens)
        #expect(good.featureTokens == 12 && good.frames.count == 3 && good.largestFramePatches == 16)
        #expect(good.frames.map(\.tokenOffset) == [p.imageOffset] + p.pairOffsets)
        // A span off its markers, a marker no span owns, an unexpanded video
        // marker, pairs out of order, an image with two pairs, images after videos.
        #expect(throws: (any Error).self) {
            try Self.validate(Self.media([Self.item(.image, [p.imageOffset + 1]), Self.item(.video, p.pairOffsets)]), p.tokens)
        }
        #expect(throws: (any Error).self) { try Self.validate(Self.media([Self.item(.video, p.pairOffsets)]), p.tokens) }
        #expect(throws: (any Error).self) {
            try Self.validate(good, p.tokens + [Self.video])
        }
        #expect(throws: (any Error).self) {
            try Self.validate(Self.media([Self.item(.image, [p.imageOffset]),
                Self.item(.video, p.pairOffsets.reversed())]), p.tokens)
        }
        #expect(throws: (any Error).self) {
            try Self.validate(Self.media([Self.item(.image, [p.imageOffset, p.pairOffsets[0]]),
                Self.item(.video, [p.pairOffsets[1]])]), p.tokens)
        }
        #expect(throws: (any Error).self) {
            try Self.validate(Self.media([Self.item(.video, p.pairOffsets), Self.item(.image, [p.imageOffset])]), p.tokens)
        }
        // Bytes whose digest differs, and a frame larger than the tower admits.
        var wrong = Self.item(.image, [p.imageOffset], bytes: Data(repeating: 8, count: 40))
        wrong = .init(kind: .image, sha256: Self.item(.image, [0]).sha256, byteCount: 40, encoded: wrong.encoded,
            temporal: 1, height: 4, width: 4, maximumPatches: 32_000, maximumQueryTokens: 16,
            maximumScoreElements: 32_000_000, patchesSHA256: Self.digest, tokenOffsets: [p.imageOffset])
        #expect(throws: (any Error).self) { try Self.media([wrong]).verifyEncodedBytes() }
        try good.verifyEncodedBytes()
        let big = ClusterGLMMedia.Item(kind: .image, sha256: Self.digest, byteCount: 40, encoded: nil, temporal: 1,
            height: 200, width: 200, maximumPatches: 32_000, maximumQueryTokens: 16, maximumScoreElements: 32_000_000,
            patchesSHA256: Self.digest, tokenOffsets: [1])
        #expect(throws: (any Error).self) { try Self.media([big]).validateStructure() }
    }

    @Test func rankZeroAloneGetsTheBytesAndBothRanksTheSameFingerprint() throws {
        let p = Self.prompt()
        // Above the ordinary command bound once base64-encoded (4/3 of the bytes).
        let large = Data((0 ..< ClusterWorkerLimits.commandBytes * 3 / 4 + 4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let items = [ClusterGLMMedia.Item(kind: .image, sha256: ClusterGLMMedia.sha256(large), byteCount: large.count,
            encoded: large, temporal: 1, height: 4, width: 4, maximumPatches: 32_000, maximumQueryTokens: 16,
            maximumScoreElements: 32_000_000, patchesSHA256: Self.digest, tokenOffsets: [p.imageOffset]),
            Self.item(.video, p.pairOffsets)]
        let media = Self.media(items)
        try Self.validate(media, p.tokens)
        func frame(_ media: ClusterGLMMedia) throws -> Data {
            try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: UUID(), sequence: 3,
                requestID: UUID(), command: .reserve(.init(profileID: ClusterGLMImageCandidate.textProfileID,
                    promptTokenIDs: p.tokens, stopTokenIDs: [1], outputCount: 8, chunkSize: 16,
                    deadlineUptimeNanoseconds: 1_000_000_000, capacityLimitBytes: 1 << 30, sampling: nil, glmMedia: media))))
        }
        // Rank 0's record is above the ordinary command bound and decodes whole.
        let zero = try frame(media)
        #expect(zero.count > ClusterWorkerLimits.commandBytes && zero.count <= ClusterWorkerLimits.mediaCommandBytes)
        guard case .command(let decoded) = try ClusterWorkerCodec.decodeControl(zero),
              case .reserve(let r) = decoded.command, let carried = r.glmMedia else {
            Issue.record("GLM media reservation did not decode"); return
        }
        #expect(carried == media && carried.carriesEncodedBytes)
        try carried.verifyEncodedBytes()
        // Rank 1's record carries digests only and stays within the ordinary bound.
        let one = try frame(media.withoutEncodedBytes)
        #expect(one.count < ClusterWorkerLimits.commandBytes)
        guard case .command(let stripped) = try ClusterWorkerCodec.decodeControl(one),
              case .reserve(let s) = stripped.command, let digests = s.glmMedia else {
            Issue.record("GLM media digests did not decode"); return
        }
        #expect(!digests.carriesEncodedBytes && digests.fingerprint == media.fingerprint)
        #expect(throws: (any Error).self) { try digests.verifyEncodedBytes() }
        // The envelope alone round-trips (the provider's request payload).
        #expect(try ClusterGLMMedia.decodeBounded(media.encoded()) == media)
        // Media rides only on the GLM row's text profile, alone.
        #expect(throws: (any Error).self) {
            try ClusterWorkerCodec.encode(ClusterWorkerCommandFrame(membershipEpoch: UUID(), sequence: 3,
                requestID: UUID(), command: .reserve(.init(profileID: "registered_qwen35_9b_greedy_generation_v1",
                    promptTokenIDs: p.tokens, stopTokenIDs: [1], outputCount: 8, chunkSize: 16,
                    deadlineUptimeNanoseconds: 1_000_000_000, capacityLimitBytes: 1 << 30, sampling: nil,
                    glmMedia: media.withoutEncodedBytes))))
        }
        // A media contract on READY round-trips; text READY has no field.
        let ready = ClusterWorkerReady(identity: ClusterWorkerIdentity(membershipEpoch: UUID(),
                modelID: ClusterGLMImageCandidate.runtimeModelID, artifactSHA256: Self.digest, configurationSHA256: Self.digest,
                peers: [.init(id: "a", buildSHA256: Self.digest), .init(id: "b", buildSHA256: Self.digest)]),
            rank: 0, profile: .init(id: ClusterGLMImageCandidate.textProfileID, vocabularySize: 32, maximumPromptTokens: 64,
                maximumOutputTokens: 8, maximumChunkTokens: 16, maximumContextTokens: 72),
            executionPlanSHA256: Self.digest, requestCapacityBytes: 1 << 30, media: ClusterGLMMedia.contract)
        let event = try ClusterWorkerCodec.encode(ClusterWorkerEventFrame(membershipEpoch: ready.identity.membershipEpoch,
            sequence: 0, requestID: nil, event: .ready(ready)))
        guard case .ready(let back) = try ClusterWorkerCodec.decodeEvent(event).event else {
            Issue.record("READY did not decode"); return
        }
        #expect(back.media == ClusterGLMMedia.contract)
    }

    /// The bulk framing reads every record a byte-at-a-time reader would, in
    /// any split, and refuses the same oversized and empty records.
    @Test func lineFramingIsSplitIndependent() throws {
        let records = [Data("{\"a\":1}\n".utf8), Data(repeating: 65, count: 70_000) + Data([10]), Data("{}\n".utf8)]
        let stream = records.reduce(Data(), +)
        for size in [1, 7, 4096, 65_536] {
            var decoder = ClusterWorkerLineDecoder(commandStream: true), out: [Data] = []
            var start = 0
            while start < stream.count {
                let stop = min(stream.count, start + size)
                out += try decoder.append(stream[start ..< stop])
                start = stop
            }
            try decoder.finish()
            #expect(out == records)
        }
        var events = ClusterWorkerLineDecoder(commandStream: false)
        #expect(throws: (any Error).self) {
            for start in stride(from: 0, to: 20_000, by: 4096) {
                _ = try events.append(Data(repeating: 65, count: min(4096, 20_000 - start)))
            }
        }
        var empty = ClusterWorkerLineDecoder(commandStream: true)
        #expect(throws: (any Error).self) { _ = try empty.append(Data([10])) }
    }

    /// The crossing: rank 0's bfloat16 features plus rank 1's -0, each widened
    /// to float32 and the sum rounded once, is every non-NaN value's own bits;
    /// +0 would turn -0 into +0.
    @Test func negativeZeroIsTheExactBroadcastOperand() {
        var changedByPositiveZero = 0
        for bits in UInt16.min ... UInt16.max {
            let value = Float(bitPattern: UInt32(bits) << 16)
            guard !value.isNaN else { continue }
            let sum = value + Float(bitPattern: 0x8000_0000)
            #expect(sum.bitPattern & 0xFFFF == 0 && UInt16(sum.bitPattern >> 16) == bits)
            if (value + Float(0)).bitPattern != value.bitPattern { changedByPositiveZero += 1 }
        }
        #expect(changedByPositiveZero == 1)
        let operand = Device.withDefaultDevice(.cpu) {
            GLM5NextTensorParallelMedia.negativeZeros([2, 3], dtype: .bfloat16)
        }
        #expect(view(operand, dtype: .uint16, stream: .cpu).asArray(UInt16.self) == Array(repeating: 0x8000, count: 6))
    }

    /// Media rows replace exactly their text rows, in any chunk cut.
    @Test func spliceReplacesOnlyMediaRows() {
        Device.withDefaultDevice(.cpu) {
            let text = MLXArray((0 ..< 30).map(Float.init), [1, 10, 3]).asType(.bfloat16)
            let first = MLXArray((100 ..< 106).map(Float.init), [2, 3]).asType(.bfloat16)
            let second = MLXArray((200 ..< 203).map(Float.init), [1, 3]).asType(.bfloat16)
            // Chunk [20, 30): media at 22..<24 and 29..<30.
            let out = GLM5NextTensorParallelMedia.splice(text: text, start: 20,
                rows: [(22 ..< 24, first), (29 ..< 30, second)])
            var expected = (0 ..< 30).map(Float.init)
            expected.replaceSubrange(6 ..< 12, with: (100 ..< 106).map(Float.init))
            expected.replaceSubrange(27 ..< 30, with: (200 ..< 203).map(Float.init))
            #expect(out.shape == [1, 10, 3] && out.dtype == .bfloat16)
            #expect(out.asType(.float32).asArray(Float.self) == expected)
        }
    }

    @Test func requestChargeCoversTheMediaAndCapacityCoversTheCharge() throws {
        let c = try GLM5NextMetadataTestFixture(layers: 8).configuration
        let p = Self.prompt()
        let media = Self.media([Self.item(.image, [p.imageOffset]), Self.item(.video, p.pairOffsets)])
        let zero = try GLM5NextTensorParallelMedia.requestBytes(media, rank: 0, configuration: c)
        let one = try GLM5NextTensorParallelMedia.requestBytes(media, rank: 1, configuration: c)
        // Rank 1 holds the agreed features and one frame's operand and sum.
        #expect(one == (12 + 4 + 4) * c.textConfig.hiddenSize * 2)
        #expect(zero > one + GLM5NextTensorParallelMedia.defaultProcessorBytes)
        #expect(try GLM5NextTensorParallelMedia.capacityBytes(rank: 0, configuration: c) >= zero)
        #expect(try GLM5NextTensorParallelMedia.capacityBytes(rank: 1, configuration: c) >= one)
    }

    // MARK: Preparation and the open's status rounds

    /// A media request on the fixture model (bfloat16 text, as the artifact).
    static func request(rank: Int) throws -> GLM5NextTensorParallelMedia {
        let p = prompt()
        let described = media([item(.image, [p.imageOffset]), item(.video, p.pairOffsets)])
        return try GLM5NextTensorParallelMedia(media: rank == 0 ? described : described.withoutEncodedBytes,
            prompt: p.tokens, configuration: try GLM5NextMetadataTestFixture(layers: 8, textDType: "bfloat16").configuration)
    }

    static func wait(until condition: () -> Bool) throws {
        let limit = Date(timeIntervalSinceNow: 10)
        while !condition() {
            guard Date() < limit else { throw ProbeError("timed out") }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    @Test func preparationRunsOffTheCallerAndJoinsOnceItEnds() throws {
        final class Gate: @unchecked Sendable { let lock = NSLock(); var open = false }
        let gate = Gate()
        let zero = try Self.request(rank: 0), one = try Self.request(rank: 1)
        // Rank 1 prepares nothing and is always joinable.
        #expect(one.joinable)
        zero.startPreparation {
            while !gate.lock.withLock({ gate.open }) { try await Task.sleep(nanoseconds: 1_000_000) }
            return [[1, 2], [3]]
        }
        // Started: not joinable, status 0, until the body returns.
        #expect(!zero.joinable)
        let prepared = zero.preparation
        #expect(prepared.status == 0)
        gate.lock.withLock { gate.open = true }
        try Self.wait { zero.joinable }
        #expect(prepared.status == 1)
        #expect(prepared.take() == [[1, 2], [3]] && prepared.take() == nil)

        // A failure is joinable with status 2; a cancel is joinable at once
        // and ends a preparation that honours cancellation.
        let failing = GLM5NextMediaPreparation()
        failing.start { throw ProbeError("decode failed") }
        try Self.wait { failing.finished }
        #expect(failing.status == 2 && failing.joinable && failing.failure != "none")
        let cancelled = GLM5NextMediaPreparation()
        cancelled.start { try await Task.sleep(nanoseconds: 60_000_000_000); return [] }
        #expect(!cancelled.joinable)
        cancelled.cancel()
        #expect(cancelled.joinable)
        try Self.wait { cancelled.finished }
        #expect(cancelled.status == 2)
    }

    /// `agreeOutcome` on two threads over an in-process sum: every round pairs.
    static func agree(status: @escaping @Sendable (Int) -> Float, stops: [@Sendable (Int) -> Bool]) throws
        -> (outcomes: [Float?], rounds: Int) {
        let link = FakeLink()
        final class Results: @unchecked Sendable {
            let lock = NSLock(); var values: [Result<Float?, Error>?] = [nil, nil]; var rounds = [0, 0]
        }
        let results = Results()
        let done = DispatchGroup()
        for rank in 0 ..< 2 {
            done.enter()
            Thread.detachNewThread {
                defer { done.leave() }
                var round = 0
                let value = Result {
                    try GLM5NextTensorParallelMedia.agreeOutcome(rank: rank, status: { status(round) },
                        stop: { stops[rank](round) }) { words in
                        defer { round += 1 }
                        return try link.exchange(rank: rank, kind: "media-status", words)
                    }
                }
                results.lock.withLock { results.values[rank] = value; results.rounds[rank] = round }
            }
        }
        guard done.wait(timeout: .now() + 20) == .success else { throw ProbeError("status rounds did not end") }
        let values = try results.lock.withLock { try results.values.map { try #require($0).get() } }
        #expect(results.rounds[0] == results.rounds[1], "both ranks run the same rounds")
        #expect(link.mismatch == nil)
        return (values, results.rounds[0])
    }

    @Test func bothRanksOpenOnTheSameOutcome() throws {
        let never: @Sendable (Int) -> Bool = { _ in false }
        // Prepared after three rounds of waiting.
        var run = try Self.agree(status: { $0 < 3 ? 0 : 1 }, stops: [never, never])
        #expect(run.outcomes == [1, 1] && run.rounds == 4)
        // A failed preparation: both ranks see it (and both throw in `open`).
        run = try Self.agree(status: { $0 < 1 ? 0 : 2 }, stops: [never, never])
        #expect(run.outcomes == [2, 2] && run.rounds == 2)
        // Rank 1 stops while rank 0 still prepares: both stop, together.
        run = try Self.agree(status: { _ in 0 }, stops: [never, { $0 >= 2 }])
        #expect(run.outcomes == [nil, nil] && run.rounds == 3)
        // Rank 0 stops in the round its preparation ends: the stop wins on both.
        run = try Self.agree(status: { $0 < 1 ? 0 : 1 }, stops: [{ $0 >= 1 }, never])
        #expect(run.outcomes == [nil, nil] && run.rounds == 2)
    }
}
