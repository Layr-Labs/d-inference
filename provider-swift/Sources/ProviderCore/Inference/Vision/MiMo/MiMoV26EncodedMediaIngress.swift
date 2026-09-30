import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import MLXVLM
import ProviderCoreFoundation

/// One bounded adaptation of the existing normalized input. Never renders
/// encoded URLs/base64, repairs arguments, fetches a URL, or starts generation.
enum MiMoV26EncodedMediaIngress {
    enum Part: Sendable {
        case text(String), image(String), video(String)
        case audio(data: String, format: OpenAIInputAudio.Format)
    }
    struct Message: Sendable {
        let role: Chat.Message.Role
        let fields: [String:any Sendable]
        let parts: [Part]
    }
    struct Plan: Sendable {
        let messages: [Message]
        let tools: [ToolSpec]?
        let context: [String:any Sendable]?
        let maximumOutputTokens: Int
        let hostBytes, initialBytes: UInt64
        let policy: MiMoV26ServingLoad.DecodedMediaPolicy
        let allowAudio: Bool // transport gate; actual loaded profile still authorizes native work
    }
    private enum ReadyPart: Sendable {
        case text(String)
        case image(Data,Int)
        case video(MiMoV26EncodedVisualDecoder.VideoPlan)
        case audio(MiMoV26EncodedAudioDecoder.Plan)
        case audiovisual(MiMoV26EncodedAudiovisualDecoder.Plan)
    }
    private struct ReadyMessage: Sendable {
        let role: Chat.Message.Role
        let fields: [String:any Sendable]
        let parts: [ReadyPart]
    }
    private static func add(_ lhs: UInt64,_ rhs: UInt64) throws -> UInt64 {
        let (value,overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw MiMoV26ServingLoadError.arithmeticOverflow }
        return value
    }
    private static func multiply(_ lhs: UInt64,_ rhs: UInt64) throws -> UInt64 {
        let (value,overflow) = lhs.multipliedReportingOverflow(by:rhs)
        guard !overflow else { throw MiMoV26ServingLoadError.arithmeticOverflow }
        return value
    }
    /// Narrow source-derived transport allowance, not measured peak memory or
    /// native admission. The extra audio URI copy remains in hostBytes through
    /// decode/native phase replacement until the existing host Task completes.
    static func transportByteBudget(encodedBound: UInt64, tableBound: UInt64,
                                    audioURIBytes: UInt64) throws
        -> (hostBytes: UInt64, initialBytes: UInt64) {
        let host = try add(try add(encodedBound,tableBound),audioURIBytes)
        let initial = try add(try multiply(encodedBound,3),
            try add(try add(tableBound,1 << 20),audioURIBytes))
        return (host,initial)
    }
    private static func refusal() -> MultiModelBatchSchedulerEngineError {
        .multimodalRejected("native media input is unsupported or exceeds its bound")
    }
    static func outwardFailure(_ error: Error) -> Error {
        if let failure = error as? MiMoV26EncodedAudioDecoder.Failure {
            switch failure {
            case .limit,.arithmeticOverflow: return MediaIngest.MediaError.mediaTooLarge("native audio input bound")
            default: return MultiModelBatchSchedulerEngineError.multimodalRejected("unsupported or malformed PCM WAV input")
            }
        }
        if let failure = error as? MiMoV26EncodedAudiovisualDecoder.Failure {
            switch failure {
            case .limit, .arithmeticOverflow:
                return MediaIngest.MediaError.mediaTooLarge("native audiovisual input bound")
            default:
                return MultiModelBatchSchedulerEngineError.multimodalRejected(
                    "video audio requires contiguous mono24k LPCM16/Float32 without edits")
            }
        }
        if let failure = error as? MiMoV26EncodedVisualDecoder.Failure {
            switch failure {
            case .limit,.arithmeticOverflow:
                return MediaIngest.MediaError.mediaTooLarge("native visual input bound")
            case .audioTrackRequiresAudiovisualProfile:
                return MultiModelBatchSchedulerEngineError.multimodalRejected(
                    "video audio requires the native audiovisual profile")
            default: return refusal()
            }
        }
        if let failure = error as? MiMoV26MultimodalError {
            switch failure {
            case .reservationRejected:
                return MultiModelBatchSchedulerEngineError.fromSchedulerMessage(
                    "token_budget_exhausted: native media memory admission refused")
            case .invalidInput,.limit,.unsupportedProfile,.missingAudioCodec:
                return refusal()
            case .cancelled: return CancellationError()
            default: return error // preserve real lifecycle/native failure, not client success
            }
        }
        if error as? MiMoV26NativeTransactionError == .unsupportedExecutionContract
            || error as? MiMoV26ServingLoadError == .managedLoadRequired {
            return MultiModelBatchSchedulerEngineError.multimodalRejected(
                "the actual loaded model has no enabled native media profile")
        }
        return error
    }

    static func plan(normalized: ProviderPromptContractPipeline.NormalizedInput,
        controls: ChatTemplateControls, maximumOutputTokens: Int,
        policy: MiMoV26ServingLoad.DecodedMediaPolicy, allowAudio: Bool = false) throws -> Plan {
        guard maximumOutputTokens > 0 else { throw refusal() }
        var context = normalized.additionalContext
        if let carrier = context?["_darkbloom_request_clock"] {
            guard case .function? = carrier as? Jinja.Value, let day = controls.promptDate?.value else {
                throw refusal()
            }
            // Preserve the SAME resolved day, never the arbitrary callable.
            context?["_darkbloom_request_clock"] = try MiMoV26MediaRequestClock(utcGregorianDay:day)
        } else if controls.promptDate != nil { throw refusal() }
        var mediaCount = 0
        var encodedBound: UInt64 = 0
        var audioURIBytes: UInt64 = 0
        var nodes = 0
        func count(_ value: Any, depth: Int = 0) throws {
            guard depth <= policy.limits.maximumMetadataDepth,
                  nodes < policy.limits.maximumMetadataNodes else { throw refusal() }
            nodes += 1
            if let values = value as? [Any] {
                for value in values { try count(value,depth:depth+1) }
            } else if let values = value as? [String:Any] {
                for (key,value) in values { try count(key,depth:depth+1); try count(value,depth:depth+1) }
            } else if let value = value as? Jinja.Value {
                switch value {
                case .array(let values): for value in values { try count(value,depth:depth+1) }
                case .object(let values):
                    for (key,value) in values { try count(key,depth:depth+1); try count(value,depth:depth+1) }
                default: break // Semantic validation belongs to the unchanged pipeline/SDK.
                }
            }
        }
        try count(normalized.messages); if let tools = normalized.tools { try count(tools) }
        let messages = try normalized.messages.map { raw -> Message in
            guard let roleText = raw["role"] as? String,
                  let role = Chat.Message.Role(rawValue:roleText) else { throw refusal() }
            var fields = raw
            fields.removeValue(forKey:"role")
            let content = fields.removeValue(forKey:"content")
            let parts: [Part]
            if let text = content as? String { parts = [.text(text)] }
            else if content == nil || content is NSNull || (content as? Jinja.Value)?.isNull == true { parts = [] }
            else if let rawParts = content as? [[String:any Sendable]] {
                parts = try rawParts.map { part in
                    switch part["type"] as? String {
                    case "text":
                        guard let text = part["text"] as? String else { throw refusal() }
                        return .text(text)
                    case "image_url", "video_url":
                        let key = part["type"] as! String
                        guard let uri = part[key] as? String, uri.hasPrefix("data:") else {
                            throw MediaIngest.MediaError.invalidURL(part[key] as? String ?? "")
                        }
                        mediaCount += 1
                        guard mediaCount <= policy.limits.maximumMedia else { throw refusal() }
                        encodedBound = try add(encodedBound,UInt64(uri.utf8.count))
                        return key == "image_url" ? .image(uri) : .video(uri)
                    case "input_audio":
                        guard allowAudio else { throw MiMoV26MultimodalError.missingAudioCodec }
                        guard let audio = part["input_audio"] as? [String:any Sendable],
                              let payload = audio["data"] as? String,
                              let spelling = audio["format"] as? String,
                              let format = OpenAIInputAudio.Format(rawValue:spelling), format == .wav else {
                            throw MultiModelBatchSchedulerEngineError.multimodalRejected("only PCM WAV input is enabled")
                        }
                        mediaCount += 1
                        guard mediaCount <= policy.limits.maximumMedia else { throw refusal() }
                        let uriBytes = try add(UInt64(payload.utf8.count),22)
                        encodedBound = try add(encodedBound,uriBytes)
                        // decode() constructs this full private URI before the
                        // existing helper extracts/filters its base64 payload.
                        audioURIBytes = try add(audioURIBytes,uriBytes)
                        return .audio(data:payload,format:format)
                    default: throw refusal()
                    }
                }
            } else { throw refusal() }
            return .init(role:role,fields:fields,parts:parts)
        }
        guard mediaCount > 0 else { throw refusal() }
        // Only new private encoded bytes/normalization containers are promised,
        // not arbitrary caller-owned body copies or any generation KV.
        let tableBound = try add(try multiply(UInt64(nodes),128),try multiply(UInt64(mediaCount),16384))
        let bytes = try transportByteBudget(encodedBound:encodedBound,tableBound:tableBound,
            audioURIBytes:audioURIBytes)
        guard bytes.initialBytes <= policy.maximumReservationBytes else { throw MiMoV26MultimodalError.reservationRejected }
        return .init(messages:messages,tools:normalized.tools,context:context,
            maximumOutputTokens:maximumOutputTokens,hostBytes:bytes.hostBytes,initialBytes:bytes.initialBytes,policy:policy,allowAudio:allowAudio)
    }

    static func decode(_ plan: consuming Plan, sampling: MiMoV26EncodedVisualDecoder.Sampling,
        reservation: MiMoV26ManagedMediaReservation) async throws -> MiMoV26MultimodalInput {
        let native = plan.policy.limits
        guard let working = Int(exactly:plan.policy.maximumReservationBytes) else { throw refusal() }
        let pixelLimit = min(MediaIngest.maxImagePixels,native.pixels.maximumInputElements / 3)
        let limits = MiMoV26EncodedVisualDecoder.Limits(maximumPixels:pixelLimit,
            maximumWorkingBytes:working,maximumSourceFrames:360_000,
            maximumSampledFrames:native.maximumVideoFrames,
            maximumEncodedBytes:MediaIngest.maxMediaDecodedBytes)
        let audiovisualLimits = MiMoV26EncodedAudiovisualDecoder.Limits(
            maximumFrames:native.audio.maximumInputSamples, maximumWorkingBytes:working,
            maximumBuffers:min(4096,native.maximumMetadataNodes),
            maximumChannels:native.audio.maximumChannels, maximumSampleRate:native.audio.maximumSampleRate)
        var imageCount = 0, videoCount = 0, audioCount = 0, totalAudioSamples = 0
        var totalImagePixels = 0, totalVideoPixels = 0, totalRGBPixels = 0
        var decodeMemory = MiMoV26MediaDecodeMemory(hostBytes: plan.hostBytes)
        var messages: [ReadyMessage] = []
        for message in plan.messages {
            var parts: [ReadyPart] = []
            for part in message.parts {
                try Task.checkCancellation()
                switch part {
                case .text(let text): parts.append(.text(text))
                case .image(let uri):
                    imageCount += 1
                    guard imageCount <= MediaIngest.maxImagesPerRequest else { throw refusal() }
                    let data = try MediaIngest.dataFromDataURI(uri)
                    try reservation.retainEncodedOwner(data as NSData)
                    guard let pixels = MediaIngest.imagePixelCount(data), pixels > 0,
                          pixels <= pixelLimit else { throw MediaIngest.MediaError.imageDecodeFailed }
                    let (sum,overflow) = totalImagePixels.addingReportingOverflow(pixels)
                    guard !overflow, sum <= MediaIngest.maxRequestImagePixels else { throw refusal() }
                    totalImagePixels = sum
                    let (rgb,overflowRGB) = totalRGBPixels.addingReportingOverflow(pixels)
                    guard !overflowRGB, rgb <= native.pixels.maximumInputElements / 3 else { throw refusal() }
                    totalRGBPixels = rgb
                    try decodeMemory.includeVisual(.image(pixels: pixels))
                    parts.append(.image(data,pixels))
                case .video(let uri):
                    videoCount += 1
                    guard videoCount <= MediaIngest.maxVideosPerRequest else { throw refusal() }
                    // Reuse the actual inline-only, typed memory-backed ingest,
                    // including duration/coded-dimension and byte guards.
                    let decoded = try await MediaIngest.decodeVideo(uri,maxFramePixels:pixelLimit)
                    guard case .memoryBacked(let owner) = decoded.video else { throw refusal() }
                    try reservation.retainEncodedOwner(owner)
                    let (sum,overflow) = totalVideoPixels.addingReportingOverflow(decoded.framePixels)
                    guard !overflow, sum <= MediaIngest.maxRequestVideoFramePixels else { throw refusal() }
                    totalVideoPixels = sum
                    let video = try await MiMoV26EncodedVisualDecoder.inspectVideo(owner,sampling:sampling,limits:limits)
                    let (pixels,overflowPixels) = video.codedPixels.multipliedReportingOverflow(by:video.sampledIndices.count)
                    let (rgb,overflowRGB) = totalRGBPixels.addingReportingOverflow(pixels)
                    guard !overflowPixels, !overflowRGB, rgb <= native.pixels.maximumInputElements / 3 else { throw refusal() }
                    totalRGBPixels = rgb
                    try decodeMemory.includeVisual(video.decodeMemory())
                    if video.hasAudioTrack {
                        guard plan.allowAudio else {
                            throw MiMoV26EncodedVisualDecoder.Failure.audioTrackRequiresAudiovisualProfile
                        }
                        guard native.audio.maximumSampleRate >= 24000,
                              native.audio.maximumChannels >= 1 else { throw refusal() }
                        audioCount += 1
                        guard audioCount <= native.audio.maximumClips else { throw refusal() }
                        let audiovisual = try await MiMoV26EncodedAudiovisualDecoder.inspect(
                            video,limits:audiovisualLimits)
                        let (sum,overflow) = totalAudioSamples.addingReportingOverflow(audiovisual.sampleCount)
                        guard !overflow, sum <= native.audio.maximumInputSamples else { throw refusal() }
                        totalAudioSamples = sum
                        try decodeMemory.includeRetained(UInt64(audiovisual.audioWorkingByteBound))
                        parts.append(.audiovisual(audiovisual))
                    } else {
                        parts.append(.video(video))
                    }
                case .audio(let payload,let format):
                    guard format == .wav, native.audio.maximumSampleRate >= 24000,
                          native.audio.maximumChannels >= 1 else { throw refusal() }
                    audioCount += 1
                    guard audioCount <= native.audio.maximumClips else { throw refusal() }
                    // Initial promise precedes this bounded base64/Data copy;
                    // the existing helper never fetches a remote/file source.
                    let data = try MediaIngest.dataFromDataURI("data:audio/wav;base64," + payload)
                    try reservation.retainEncodedOwner(data as NSData)
                    let audio = try MiMoV26EncodedAudioDecoder.inspect(data,
                        limits:.init(maximumEncodedBytes:MediaIngest.maxMediaDecodedBytes,
                            maximumFrames:native.audio.maximumInputSamples,maximumWorkingBytes:working,
                            maximumChunks:min(4096,native.maximumMetadataNodes),
                            maximumChannels:native.audio.maximumChannels,
                            maximumSampleRate:native.audio.maximumSampleRate))
                    let (sum,overflow) = totalAudioSamples.addingReportingOverflow(audio.sampleCount)
                    guard !overflow, sum <= native.audio.maximumInputSamples else { throw refusal() }
                    totalAudioSamples = sum
                    try decodeMemory.includeRetained(UInt64(audio.decodedByteBound))
                    parts.append(.audio(audio))
                }
            }
            messages.append(.init(role:message.role,fields:message.fields,parts:parts))
        }
        // Actual source geometry/counts are now known; grow the SAME charge
        // before ImageIO raster copies or decoded AV frame buffers are created.
        // Retain every result, but only one image/frame decoder runs at a time.
        try reservation.reserveDecodeWorkingBytes(decodeMemory.peakBytes)
        var decodedMessages: [MiMoV26MultimodalMessage] = []
        for message in messages {
            var content: [MiMoV26MultimodalContent] = []
            for part in message.parts {
                try Task.checkCancellation()
                switch part {
                case .text(let text): content.append(.text(text))
                case .image(let data,_):
                    content.append(.image(try MiMoV26EncodedVisualDecoder.image(data,limits:limits)))
                case .video(let video):
                    content.append(.silentVideo(try await MiMoV26EncodedVisualDecoder.silentVideo(video,limits:limits)))
                case .audio(let audio):
                    content.append(.audio(try MiMoV26EncodedAudioDecoder.decode(audio)))
                case .audiovisual(let audiovisual):
                    content.append(.audiovisual(try await MiMoV26EncodedAudiovisualDecoder.decode(
                        audiovisual,videoLimits:limits,audioLimits:audiovisualLimits)))
                }
            }
            decodedMessages.append(.init(role:message.role,content:content,templateFields:message.fields))
        }
        try Task.checkCancellation()
        return .init(messages:decodedMessages,tools:plan.tools,additionalContext:plan.context,
            maximumOutputTokens:plan.maximumOutputTokens)
    }
}
