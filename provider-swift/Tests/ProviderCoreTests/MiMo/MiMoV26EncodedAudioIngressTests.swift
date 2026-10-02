import Foundation
import MLXLMServer
import XCTest
@testable import MLXLMCommon
@testable import MLXVLM
@testable import ProviderCore

/// Actual typed parsing/normalization, real ledger and exact native PCM input.
/// No scripted generator success and no claim of loaded-model/HTTP qualification.
final class MiMoV26EncodedAudioIngressTests: XCTestCase {
    private func wave() -> Data {
        func u16(_ x: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded:x),UInt8(truncatingIfNeeded:x >> 8)] }
        func u32(_ x: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded:x),UInt8(truncatingIfNeeded:x >> 8),
             UInt8(truncatingIfNeeded:x >> 16),UInt8(truncatingIfNeeded:x >> 24)]
        }
        let samples = (0..<480).flatMap { _ in [UInt16(0x8000),0xffff,0,1,0x7fff] }.flatMap(u16)
        let fmt = u16(1)+u16(1)+u32(24000)+u32(48000)+u16(2)+u16(16)
        let body = Array("WAVEfmt ".utf8)+u32(16)+fmt+Array("data".utf8)+u32(UInt32(samples.count))+samples
        return Data(Array("RIFF".utf8)+u32(UInt32(body.count))+body)
    }
    private func body(format: String = "wav",data: String? = nil,responses: Bool = false) throws -> Data {
        let content: [[String:Any]] = [
            ["type":"text","text":"before"],
            ["type":"input_audio","input_audio":["format":format,"data":data ?? wave().base64EncodedString()]],
            ["type":"text","text":"after"]
        ]
        let messages: [[String:Any]] = [["role":"user","content":content]]
        return try JSONSerialization.data(withJSONObject:[
            "model":"fixture","enable_thinking":false,responses ? "max_output_tokens" : "max_tokens":2,
            responses ? "input" : "messages":messages
        ])
    }
    private func parsed(_ body: Data,responses: Bool = false) throws -> (OpenAIChatCompletionRequest,ChatTemplateControls) {
        if responses {
            let value = try JSONDecoder().decode(LocalResponseRequest.self,from:body)
            return (value.request.chatCompletionRequest,value.templateControls)
        }
        return (try ProviderLoop.decodeOpenAIRequest(body),ProviderLoop.extractChatTemplateControls(from:body))
    }
    private func normalized(_ pair: (OpenAIChatCompletionRequest,ChatTemplateControls)) throws
        -> ProviderPromptContractPipeline.NormalizedInput {
        try ProviderPromptContractPipeline.normalizedInput(
            prepared:ToolChoicePromptPolicy.prepare(pair.0,modelType:"mimo_v2"),request:pair.0,
            modelType:"mimo_v2",templateControls:pair.1,preserveMiMoMediaParts:true)
    }
    private func policy(maximumSamples: Int = 48000) throws -> MiMoV26ServingLoad.DecodedMediaPolicy {
        try .init(limits:.init(maximumMedia:4,maximumVideoFrames:4,maximumPromptTokens:2048,
            maximumMetadataBytes:65536,maximumMetadataNodes:10000,maximumMetadataDepth:32,
            pixels:.init(maximumInputElements:100000,maximumOutputElements:100000,maximumWorkingBytes:1 << 20),
            vision:.init(maximumPatches:256,maximumAttentionScoreElements:131072),
            audio:.init(maximumClips:2,maximumChannels:2,maximumSampleRate:192000,
                maximumInputSamples:maximumSamples,maximumResampledSamples:maximumSamples,
                maximumResampleCoefficients:100000,maximumMelFrames:256,maximumSegments:4,
                maximumPaddedMelFrames:256,maximumWorkingElements:64_000_000,frontendFrameBlockSize:8,rvqTileFrames:8),
            audioPatch:.init(maximumClips:2,maximumFrames:256,maximumPatches:64,maximumWorkingElements:16_000_000)),
            maximumReservationBytes:32 << 20,additionalSystemReserveBytes:1)
    }
    private func decode(_ pair: (OpenAIChatCompletionRequest,ChatTemplateControls),
                        policy: MiMoV26ServingLoad.DecodedMediaPolicy) async throws -> MiMoV26MultimodalInput {
        let value = try MiMoV26EncodedMediaIngress.plan(normalized:normalized(pair),controls:pair.1,
            maximumOutputTokens:2,policy:policy,allowAudio:true)
        // CPU decode only: this controlled ledger does not admit model work or
        // claim an issued profile. Production obtains authority from real bridge/TX.
        let ledger = ProcessMemoryLedger(policy:.init(epoch:1,capBytes:64 << 20,reserveBytes:0),
            readUsage:{ .init(activeBytes:0,cacheBytes:0,systemAvailableBytes:128 << 20) })
        let reservation = try MiMoV26ManagedMediaReservation(initialBytes:value.initialBytes,hostBytes:value.hostBytes,
            maximumBytes:policy.maximumReservationBytes,additionalSystemReserveBytes:1,ledger:ledger,serviceBudget:.init())
        defer {
            reservation.abortBeforeNativeAdoption()
            do { try reservation.completeHostOwnership() } catch { XCTFail("CPU-only exact owner settlement failed") }
            XCTAssertEqual(ledger.snapshot().chargedBytes,0)
        }
        return try await MiMoV26EncodedMediaIngress.decode(value,
            sampling:.init(fps:1,minimumFrames:8,maximumFrames:3600),reservation:reservation)
    }
    func testChatAndResponsesPreserveTypedAudioAndExactlyMatchedNativePCMInput() async throws {
        for responses in [false,true] {
            let pair = try parsed(body(responses:responses),responses:responses)
            XCTAssertEqual(pair.0.maxTokens,2)
            XCTAssertTrue(MediaIngest.hasMedia(pair.0)); XCTAssertTrue(MediaIngest.hasAudio(pair.0))
            XCTAssertTrue(pair.0.messages[0].content.hasMedia)
            guard case .parts(let parts) = pair.0.messages[0].content,
                  case .inputAudio(let audio) = parts[1] else { return XCTFail("typed bytes lost") }
            XCTAssertEqual(audio.format,.wav)
            XCTAssertEqual(Data(base64Encoded:audio.data),wave())
            let input = try await decode(pair,policy:policy())
            guard input.messages.count == 1, input.messages[0].content.count == 3,
                  case .text("before") = input.messages[0].content[0],
                  case .audio(let pcm) = input.messages[0].content[1],
                  case .text("after") = input.messages[0].content[2] else { return XCTFail("native input ordering lost") }
            XCTAssertEqual(pcm.descriptor.frameCount,2400)
            XCTAssertEqual(pcm.descriptor.channels,1); XCTAssertEqual(pcm.descriptor.sampleRate,24000)
            let bits: [UInt32] = [0xbf800000,0xb8000000,0,0x38000000,0x3f7ffe00]
            XCTAssertEqual(pcm.samples.map(\.bitPattern),(0..<480).flatMap { _ in bits })
            XCTAssertEqual(pcm.descriptor.sourceIdentity,MiMoConsumerFixture.sha(wave()))
            XCTAssertEqual(input.additionalContext?["enable_thinking"] as? Bool,false)
            XCTAssertNil(input.messages[0].templateFields["input_audio"])
        }
    }
    func testOpenRouterPCM8ShapeTraversesChatAndResponsesIngress() async throws {
        var sample = wave()
        // Replace the existing mono PCM16 payload with the same number of
        // PCM8 samples at the real failing request's 22.05 kHz input rate.
        var bytes = Array(sample.prefix(44))
        let frames = 2400
        func put(_ value: Int, at offset: Int, width: Int) {
            for i in 0..<width { bytes[offset+i] = UInt8(truncatingIfNeeded:value >> (8*i)) }
        }
        put(36 + frames,at:4,width:4); put(22050,at:24,width:4)
        put(22050,at:28,width:4); put(1,at:32,width:2); put(8,at:34,width:2)
        put(frames,at:40,width:4)
        sample = Data(bytes + Array(repeating:UInt8(192),count:frames))
        for responses in [false,true] {
            let input = try await decode(parsed(body(data:sample.base64EncodedString(),responses:responses),
                responses:responses),policy:policy())
            guard case .audio(let pcm) = input.messages[0].content[1] else { return XCTFail("audio lost") }
            XCTAssertEqual(pcm.descriptor.sampleRate,22050)
            XCTAssertEqual(pcm.descriptor.channels,1)
            XCTAssertEqual(pcm.samples.count,frames)
            XCTAssertTrue(pcm.samples.allSatisfy { $0 == 0.5 })
        }
    }

    func testTypedWireRoundtripAndMalformedPayloadTypes() throws {
        let pair = try parsed(body())
        let roundtrip = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from:JSONEncoder().encode(pair.0))
        XCTAssertEqual(roundtrip,pair.0)
        for audio in [NSNull(),["data":1,"format":"wav"],["data":"AA==","format":false],
                      ["data":"AA==","format":"ogg"],["format":"wav"]] as [Any] {
            let data = try JSONSerialization.data(withJSONObject:["model":"fixture","messages":[
                ["role":"user","content":[["type":"input_audio","input_audio":audio]]]]])
            XCTAssertThrowsError(try ProviderLoop.decodeOpenAIRequest(data))
        }
    }
    func testWrongProfileMP3AndNonNativeFamilyRemainExplicitRefusals() async throws {
        let pair = try parsed(body()), value = try normalized(pair)
        XCTAssertThrowsError(try ProviderPromptContractPipeline.normalizedInput(
            prepared:ToolChoicePromptPolicy.prepare(pair.0,modelType:"mimo_v2"),request:pair.0,
            modelType:"mimo_v2",templateControls:pair.1))
        XCTAssertThrowsError(try MiMoV26EncodedMediaIngress.plan(normalized:value,controls:pair.1,
            maximumOutputTokens:2,policy:policy())) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError,.missingAudioCodec)
        }
        let mp3 = try parsed(body(format:"mp3"))
        XCTAssertThrowsError(try MiMoV26EncodedMediaIngress.plan(normalized:normalized(mp3),controls:mp3.1,
            maximumOutputTokens:2,policy:policy(),allowAudio:true))
        do { _ = try await MediaIngest.buildUserInput(from:pair.0,modelType:"llama"); XCTFail("generic vision dropped audio") }
        catch { XCTAssertTrue(error is MultiModelBatchSchedulerEngineError) }
    }
    func testMalformedBase64WaveAndAggregateFrameBoundRefuseWithoutNativeWork() async throws {
        for data in ["https://example.invalid/audio.wav","file:///private/audio.wav","AAAA"] {
            do { _ = try await decode(parsed(body(data:data)),policy:policy()); XCTFail("bad encoded audio accepted") }
            catch { XCTAssertTrue(error is MediaIngest.MediaError || error is MiMoV26EncodedAudioDecoder.Failure) }
        }
        do { _ = try await decode(parsed(body()),policy:policy(maximumSamples:2399)); XCTFail("sample ceiling bypass") }
        catch { XCTAssertEqual(error as? MiMoV26EncodedAudioDecoder.Failure,.limit) }
    }
    func testDecoderCancellationIsNotACompletedPCMResult() async throws {
        let plan = try MiMoV26EncodedAudioDecoder.inspect(wave(),
            limits:.init(maximumEncodedBytes:65536,maximumFrames:48000,maximumWorkingBytes:1 << 20))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MiMoV26EncodedAudioDecoder.decode(plan)
        }
        do { _ = try await task.value; XCTFail("cancelled decode completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
