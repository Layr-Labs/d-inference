import Foundation
import MLXLMServer
import XCTest
@testable import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

/// Actual normalized transport + real phased ledger. No issued native profile,
/// model, generated features, synthetic completion or native execution.
final class MiMoV26EncodedAudiovisualIngressTests: XCTestCase {
    private func policy(maximumClips: Int = 2) throws -> MiMoV26ServingLoad.DecodedMediaPolicy {
        try .init(limits:.init(maximumMedia:4,maximumVideoFrames:4,maximumPromptTokens:2048,
            maximumMetadataBytes:65536,maximumMetadataNodes:10000,maximumMetadataDepth:32,
            pixels:.init(maximumInputElements:100000,maximumOutputElements:100000,maximumWorkingBytes:1 << 20),
            vision:.init(maximumPatches:256,maximumAttentionScoreElements:131072),
            audio:.init(maximumClips:maximumClips,maximumChannels:1,maximumSampleRate:24000,
                maximumInputSamples:48000,maximumResampledSamples:48000,
                maximumResampleCoefficients:100000,maximumMelFrames:512,maximumSegments:4,
                maximumPaddedMelFrames:512,maximumWorkingElements:64_000_000,frontendFrameBlockSize:8,rvqTileFrames:8),
            audioPatch:.init(maximumClips:maximumClips,maximumFrames:256,maximumPatches:64,maximumWorkingElements:16_000_000)),
            maximumReservationBytes:32 << 20,additionalSystemReserveBytes:1)
    }
    private func plan(_ data: Data, allowAudio: Bool, count: Int = 1, maximumClips: Int = 2) throws
        -> MiMoV26EncodedMediaIngress.Plan {
        let uri = "data:video/quicktime;base64," + data.base64EncodedString()
        let parts: [[String:Any]] = [["type":"text","text":"before"]]
            + (0..<count).map { _ in ["type":"video_url","video_url":["url":uri]] }
            + [["type":"text","text":"after"]]
        let body = try JSONSerialization.data(withJSONObject:[
            "model":"fixture","enable_thinking":false,"max_tokens":2,
            "messages":[["role":"user","content":parts]]])
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let controls = ProviderLoop.extractChatTemplateControls(from:body)
        let normalized = try ProviderPromptContractPipeline.normalizedInput(
            prepared:ToolChoicePromptPolicy.prepare(request,modelType:"mimo_v2"),request:request,
            modelType:"mimo_v2",templateControls:controls,preserveMiMoMediaParts:true)
        return try MiMoV26EncodedMediaIngress.plan(normalized:normalized,controls:controls,
            maximumOutputTokens:2,policy:policy(maximumClips:maximumClips),allowAudio:allowAudio)
    }
    private static func decode(_ plan: MiMoV26EncodedMediaIngress.Plan,
                        cap: UInt64 = 64 << 20) async throws -> MiMoV26MultimodalInput {
        let ledger = ProcessMemoryLedger(policy:.init(epoch:1,capBytes:cap,reserveBytes:0),
            readUsage:{ .init(activeBytes:0,cacheBytes:0,systemAvailableBytes:128 << 20) })
        let reservation = try MiMoV26ManagedMediaReservation(
            initialBytes:plan.initialBytes,hostBytes:plan.hostBytes,
            maximumBytes:plan.policy.maximumReservationBytes,additionalSystemReserveBytes:1,ledger:ledger)
        XCTAssertGreaterThan(ledger.snapshot().chargedBytes,0)
        defer {
            reservation.abortBeforeNativeAdoption()
            do { try reservation.completeHostOwnership() }
            catch { XCTFail("real CPU host owner did not settle: \(error)") }
            XCTAssertEqual(ledger.snapshot().chargedBytes,0)
        }
        return try await MiMoV26EncodedMediaIngress.decode(plan,
            sampling:.init(fps:1,minimumFrames:8,maximumFrames:3600),reservation:reservation)
    }
    func testGenuineAVTransportPreservesOneOrderedPartAndAllPCM() async throws {
        let input = try await Self.decode(plan(MiMoAVFixture.movie(),allowAudio:true))
        XCTAssertEqual(input.messages.count,1)
        XCTAssertEqual(input.messages[0].content.count,3)
        guard case .text("before") = input.messages[0].content[0],
              case .audiovisual(let value) = input.messages[0].content[1],
              case .text("after") = input.messages[0].content[2] else {
            return XCTFail("audio/video were dropped, separated or reordered")
        }
        XCTAssertEqual(value.frames.count,2)
        XCTAssertEqual(value.timestamps.map(\.bitPattern),[Float(0).bitPattern,(Float(2)/Float(3)).bitPattern])
        XCTAssertEqual(value.wholeAudio.samples.count,24000)
        let expectedSamples: [Float] = [-1, -1.0 / 32768, 0, 1.0 / 32768, 32767.0 / 32768]
        XCTAssertEqual(Array(value.wholeAudio.samples.prefix(5)).map(\.bitPattern),
            expectedSamples.map(\.bitPattern))
        XCTAssertNil(input.messages[0].templateFields["video_url"])
        XCTAssertEqual(input.maximumOutputTokens,2)
    }
    func testNoAudioProfileStillRejectsActualSoundAndSilentVideoStillWorks() async throws {
        do { _ = try await Self.decode(plan(MiMoAVFixture.movie(),allowAudio:false)); XCTFail("sound bypass") }
        catch { XCTAssertEqual(error as? MiMoV26EncodedVisualDecoder.Failure,
                               .audioTrackRequiresAudiovisualProfile) }
        let silent = try XCTUnwrap(Data(base64Encoded:MiMoAVFixture.videoBase64))
        let input = try await Self.decode(plan(silent,allowAudio:false))
        guard case .silentVideo(let video) = input.messages[0].content[1] else {
            return XCTFail("silent behavior changed")
        }
        XCTAssertEqual(video.frames.count,2)
    }
    func testRealLedgerGrowthRefusalWinsBeforeNonfinitePCMDecodeAndReleasesCharge() async throws {
        let value = try plan(MiMoAVFixture.movie(floatBits:[0x7fc00001]),allowAudio:true)
        // Initial ownership is genuinely admitted; actual decode phase growth
        // exceeds this ledger cap. If PCM decode ran first, this is a NaN error.
        do { _ = try await Self.decode(value,cap:value.initialBytes + 128); XCTFail("growth bypass") }
        catch { XCTAssertEqual(error as? MiMoV26MultimodalError,.reservationRejected) }
    }
    func testAggregateAudioClipBoundCountsVideoBorneAudioAndDoesNotDropIt() async throws {
        do { _ = try await Self.decode(plan(MiMoAVFixture.movie(),allowAudio:true,count:2,maximumClips:1))
            XCTFail("AV clips bypassed audio count") }
        catch { XCTAssertTrue(error is MultiModelBatchSchedulerEngineError) }
    }
    func testRateChannelAndDecoderFaultRefusalsSettleActualHostLease() async throws {
        for (data,expected) in [
            (try MiMoAVFixture.movie(rate:22050),MiMoV26EncodedAudiovisualDecoder.Failure.unsupportedSampleRate),
            (try MiMoAVFixture.movie(channels:2),.unsupportedChannels),
            (try MiMoAVFixture.movie(floatBits:[0x7f800000]),.nonfiniteSamples)] {
            do { _ = try await Self.decode(plan(data,allowAudio:true)); XCTFail("unsupported sound accepted") }
            catch { XCTAssertEqual(error as? MiMoV26EncodedAudiovisualDecoder.Failure,expected) }
        }
        let mapped = MiMoV26EncodedMediaIngress.outwardFailure(
            MiMoV26EncodedAudiovisualDecoder.Failure.unsupportedEncoding)
        XCTAssertTrue(mapped is MultiModelBatchSchedulerEngineError)
        let cancellation = MiMoV26EncodedMediaIngress.outwardFailure(CancellationError())
        XCTAssertTrue(cancellation is CancellationError)
        // Narrow transport mapping must not swallow arbitrary native faults.
        let native = NSError(domain:"real-native-fault",code:7)
        XCTAssertTrue((MiMoV26EncodedMediaIngress.outwardFailure(native) as NSError) === native)
    }
    func testCancelledHostDecodeReleasesOneRealReservation() async throws {
        let value = try plan(MiMoAVFixture.movie(),allowAudio:true)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Self.decode(value)
        }
        do { _ = try await task.value; XCTFail("cancelled request produced AV") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

/// A real ISO-BMFF fixture: retain the pre-existing three-frame H.264 mdat and
/// video track byte-for-byte, append one bounded uncompressed audio mdat/track.
/// Pure Swift byte construction only; AVAssetReader remains the actual decoder.
/// The two test targets deliberately carry identical private fixture builders.
private enum MiMoAVFixture {
    static let videoBase64 = "AAAAHGZ0eXBtcDQyAAAAAWlzb21tcDQxbXA0MgAAAAFtZGF0AAAAAAAAAK4AAAA7BgUyR1ZK3FxMQz+U78URPNFDqAEAAAMAAQMAAAMAAQIAAeYACwAAAwAAAwAAAwAUDAOJJAEN/////4AAAAAxJbggH4AuSqwRNmYXSACJwyG5akafRwrPDoFqVCtjHBP+QvRWhyAAGk1PzfAEsEedgAAAABEh4QhfAoAvQrFXFN4ACQ7CtgAAABEBqIGK/1jQw/VufW+ACvdnuAAAAvFtb292AAAAbG12aGQAAAAA5lOws+ZTsLMAAAJYAAACWAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACfXRyYWsAAABcdGtoZAAAAAHmU7Cz5lOwswAAAAEAAAAAAAACWAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAlgAAADIAAEAAAAAAfVtZGlhAAAAIG1kaGQAAAAA5lOws+ZTsLMAAAJYAAACWFXEAAAAAAAxaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAENvcmUgTWVkaWEgVmlkZW8AAAABnG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAVxzdGJsAAAAoXN0c2QAAAAAAAAAAQAAAJFhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAJ2F2Y0MBZAAL/+EADCdkAAusVlDDeBBhFAEABCjuPLD9+PgAAAAACmZpZWwBAAAAAApjaHJtAAAAAAAYc3R0cwAAAAAAAAABAAAAAwAAAMgAAAAoY3R0cwAAAAAAAAADAAAAAQAAAMgAAAABAAABkAAAAAEAAAAAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAPc2R0cAAAAAAgEBgAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAMAAAABAAAAIHN0c3oAAAAAAAAAAAAAAAMAAAB0AAAAFQAAABUAAAAUc3RjbwAAAAAAAAABAAAALA=="
    static func be(_ value: UInt64, _ width: Int = 4) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func atom(_ name: String, _ body: Data) -> Data {
        be(UInt64(body.count + 8)) + Data(name.utf8) + body
    }
    static let matrix = [UInt64(0x10000),0,0,0,0x10000,0,0,0,0x40000000]
        .reduce(into: Data()) { $0.append(be($1)) }
    static let frames = 24000
    static func movie(floatBits: [UInt32]? = nil, rate: Int = 24000, channels: Int = 1,
                      codec: String? = nil, edited: Bool = false, duplicateTrack: Bool = false) throws -> Data {
        let original = try XCTUnwrap(Data(base64Encoded: videoBase64))
        let step = floatBits == nil ? 2 : 4
        var pcm = Data()
        for i in 0..<frames {
            let bits = floatBits.map { $0[i % $0.count] }
                ?? UInt32([UInt16(0x8000),0xffff,0,1,0x7fff][i % 5])
            for _ in 0..<channels {
                for byte in 0..<step { pcm.append(UInt8(truncatingIfNeeded: bits >> (byte * 8))) }
            }
        }
        func track(offset: Int, id: Int = 2) -> Data {
            let duration = UInt64(frames * 600 / rate)
            let tkhdFields: [Data] = [be(7), be(0), be(0), be(UInt64(id)), be(0), be(duration),
                Data(repeating: 0, count: 12), be(0x100,2), be(0,2), matrix, be(0), be(0)]
            let tkhd = atom("tkhd", tkhdFields.reduce(into: Data()) { $0.append($1) })
            let mdhd = atom("mdhd", Data(repeating: 0, count: 12) + be(UInt64(rate)) + be(UInt64(frames))
                + be(0x55c4,2) + be(0,2))
            let hdlr = atom("hdlr", Data(repeating: 0, count: 8) + Data("soun".utf8)
                + Data(repeating: 0, count: 12) + Data("Sound\0".utf8))
            let sample: Data
            if floatBits != nil {
                // QuickTime SoundDescription V2, LPCM float32 little-endian,
                // packed, 1 PCM frame/packet. No platform conversion request.
                let common = Data(repeating: 0, count: 6) + be(1,2) + be(2,2) + be(0,2) + be(0)
                    + be(3,2) + be(16,2) + be(0xfffe,2) + be(0,2) + be(0x10000)
                let extended = be(72) + be(Double(rate).bitPattern,8) + be(UInt64(channels))
                    + be(0x7f000000) + be(32) + be(9) + be(UInt64(step * channels)) + be(1)
                sample = atom(codec ?? "lpcm", common + extended)
            } else {
                let body = Data(repeating: 0, count: 6) + be(1,2) + Data(repeating: 0, count: 8)
                    + be(UInt64(channels),2) + be(16,2) + be(0,2) + be(0,2) + be(UInt64(rate) << 16)
                sample = atom(codec ?? "sowt", body)
            }
            let stsd = atom("stsd", be(0) + be(1) + sample)
            let stts = atom("stts", be(0) + be(1) + be(UInt64(frames)) + be(1))
            let stsc = atom("stsc", be(0) + be(1) + be(1) + be(UInt64(frames)) + be(1))
            let stsz = atom("stsz", be(0) + be(UInt64(step * channels)) + be(UInt64(frames)))
            let stco = atom("stco", be(0) + be(1) + be(UInt64(offset)))
            let stbl = atom("stbl", stsd + stts + stsc + stsz + stco)
            let dinf = atom("dinf", atom("dref", be(0) + be(1) + atom("url ", be(1))))
            let minf = atom("minf", atom("smhd", Data(repeating: 0, count: 8)) + dinf + stbl)
            let edit = edited ? atom("edts", atom("elst",
                be(0) + be(1) + be(duration) + be(1) + be(0x10000))) : Data()
            return atom("trak", tkhd + edit + atom("mdia", mdhd + hdlr + minf))
        }
        // This bound fixture's last atom is moov; existing stco offsets remain
        // unchanged because only the tail moov grows, then a new mdat is added.
        var moovStart = 0
        while moovStart < original.count {
            let n = original[moovStart..<moovStart+4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let type = String(data: original[moovStart+4..<moovStart+8], encoding: .ascii)
            if type == "moov" { break }
            let actual = n == 1 ? original[moovStart+8..<moovStart+16]
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } : n
            guard actual >= 8, actual <= UInt64(original.count - moovStart) else {
                throw NSError(domain: "MiMoAVFixture", code: 1)
            }
            moovStart += Int(actual)
        }
        let addition = track(offset: 0).count * (duplicateTrack ? 2 : 1)
        let offset = original.count + addition + 8
        var body = Data(original[(moovStart + 8)...])
        // mvhd's final next_track_ID; movie/video payload otherwise unchanged.
        let mvhdSize = body.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        body.replaceSubrange((mvhdSize - 4)..<mvhdSize, with: be(duplicateTrack ? 4 : 3))
        body += track(offset: offset)
        if duplicateTrack { body += track(offset: offset, id: 3) }
        var prefix = Data(original.prefix(moovStart))
        // LPCM sound descriptions use the QuickTime container contract.
        // Retain byte offsets/lengths; video track and video mdat are unchanged.
        prefix.replaceSubrange(8..<12,with:Data("qt  ".utf8))
        prefix.replaceSubrange(16..<28,with:Data("qt  qt  qt  ".utf8))
        return prefix + atom("moov", body) + atom("mdat", pcm)
    }
}
