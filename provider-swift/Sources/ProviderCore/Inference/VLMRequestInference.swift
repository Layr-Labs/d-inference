// Copyright © 2026 Eigen Labs.
//
// Non-batched vision-language inference path.
//
// The continuous-batching engine (`BatchScheduler` / `BatchedEngine`)
// carries only `[Int]` token arrays, so it cannot represent image/video
// pixels. Multimodal requests for a VLM model are served here instead:
// we build a `UserInput` carrying the decoded media, `prepare` it into an
// `LMInput`, and stream `container.generate(...)`. This mirrors exactly
// the prepare → generate path proven by `Sources/vlm-smoke/main.swift`.
//
// Text-only requests never reach this file — they stay on the batched
// engine. Routing lives in
// `MultiModelBatchSchedulerEngine.streamChatCompletion`, which calls
// `VLMRequestInference.hasMedia` and, when true for a VLM model,
// delegates to `VLMRequestInference.stream`.

import CoreImage
import Foundation
import MLXLMCommon
import MLXLMServer

/// Namespace for the non-batched VLM (image/video) inference path.
///
/// Pure functions + one streaming entry point; holds no state. The
/// container is owned by `ProviderLoop`'s `ModelSlot` and passed in.
public enum VLMRequestInference {

    /// Errors surfaced while decoding inline media from a request. These
    /// finish the stream via `continuation.finish(throwing:)` so the
    /// status mapper can turn them into a 4xx for the caller.
    ///
    /// Conforms to `LocalizedError` so the human-readable `description`
    /// reaches the client (via `error.localizedDescription`) instead of
    /// the generic Cocoa "operation couldn't be completed" fallback.
    public enum MediaError: Error, CustomStringConvertible, LocalizedError {
        case malformedDataURI(String)
        case base64DecodeFailed
        case percentDecodeFailed
        case imageDecodeFailed
        case invalidURL(String)
        case videoWriteFailed(String)

        public var description: String {
            switch self {
            case .malformedDataURI(let detail):
                return "malformed data: URI (\(detail))"
            case .base64DecodeFailed:
                return "failed to base64-decode data: URI payload"
            case .percentDecodeFailed:
                return "failed to percent-decode data: URI payload"
            case .imageDecodeFailed:
                return "failed to decode image data into a CIImage"
            case .invalidURL(let uri):
                // Actionable for clients porting from OpenAI/OpenRouter: our wire
                // format is identical, but media must be an inline base64 data:
                // URI — remote/file URLs are rejected for E2E + SSRF safety.
                let shown = uri.count > 200 ? String(uri.prefix(200)) + "…" : uri
                return "media must be sent as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\") on this end-to-end-encrypted endpoint; remote http(s):// and file:// URLs are rejected. Got: \(shown)"
            case .videoWriteFailed(let detail):
                return "failed to write inline video to a temp file (\(detail))"
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - Routing

    /// True when any message carries an image or video content part.
    /// Used by the engine to decide between the batched (text) path and
    /// this non-batched vision path.
    public static func hasMedia(_ request: OpenAIChatCompletionRequest) -> Bool {
        for message in request.messages {
            guard case .parts(let parts) = message.content else { continue }
            for part in parts {
                switch part {
                case .imageURL, .videoURL:
                    return true
                case .text, .unsupported:
                    continue
                }
            }
        }
        return false
    }

    // MARK: - Streaming

    /// Stream a multimodal completion through the container's
    /// `prepare`/`generate` vision path.
    ///
    /// Emits the same `MLXServerGenerationEvent` shape as the batched
    /// engine so the surrounding HTTP/SSE plumbing is identical:
    /// `.content` chunks during generation, then a final `.info` carrying
    /// token counts and timing. Inline-video temp files are removed when
    /// the stream ends (normal completion, error, or cancellation).
    public static func stream(
        container: ModelContainer,
        request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int
    ) -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Inline `data:` videos are materialized to temp files for
                // AVFoundation; track them so we can clean up on exit.
                var tempFiles: [URL] = []
                defer {
                    for url in tempFiles {
                        try? FileManager.default.removeItem(at: url)
                    }
                }

                let userInput: UserInput
                do {
                    userInput = try buildUserInput(from: request, tempFiles: &tempFiles)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    // Capture the prompt-clock origin BEFORE `prepare` so the
                    // reported `promptTime` includes media decode / resize /
                    // tokenization, matching the batched + server engines
                    // (which start their clock before any prep work). Capturing
                    // it after `prepare` would undercount prompt latency.
                    let startedAt = Date()
                    let lmInput = try await container.prepare(input: userInput)

                    let params = GenerateParameters(
                        maxTokens: request.maxTokens ?? defaultMaxTokens,
                        temperature: request.temperature ?? 0,
                        topP: request.topP ?? 1.0,
                        topK: request.topK ?? 0,
                        repetitionPenalty: request.repetitionPenalty
                    )

                    let genStream = try await container.generate(
                        input: lmInput, parameters: params)

                    var promptTokens = 0
                    var completionTokens = 0
                    var firstTokenAt: Date?
                    var lastTokenAt: Date?
                    // Default to "stop"; overwritten from the engine's
                    // GenerateCompletionInfo so we report the real finish
                    // reason (e.g. "length" when maxTokens is hit) instead of
                    // a hardcoded value.
                    var stopReason = "stop"

                    for await gen in genStream {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        switch gen {
                        case .chunk(let text):
                            if firstTokenAt == nil { firstTokenAt = Date() }
                            lastTokenAt = Date()
                            if !text.isEmpty {
                                continuation.yield(.content(text))
                            }
                        case .info(let info):
                            promptTokens = info.promptTokenCount
                            completionTokens = info.generationTokenCount
                            stopReason = openAIFinishReason(info.stopReason)
                        case .toolCall(let toolCall):
                            continuation.yield(.toolCall(toolCall))
                        }
                    }

                    let promptTime = (firstTokenAt ?? startedAt)
                        .timeIntervalSince(startedAt)
                    let generationTime = (lastTokenAt ?? firstTokenAt ?? startedAt)
                        .timeIntervalSince(firstTokenAt ?? startedAt)
                    continuation.yield(
                        .info(
                            ServerGenerationInfo(
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                promptTime: max(0, promptTime),
                                generationTime: max(0, generationTime),
                                stopReason: stopReason
                            )
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - UserInput construction

    /// Build a model-agnostic `UserInput` from the OpenAI request,
    /// decoding any inline image/video content parts. `tempFiles`
    /// accumulates temp URLs created for inline videos so the caller can
    /// remove them when the stream ends.
    static func buildUserInput(
        from request: OpenAIChatCompletionRequest,
        tempFiles: inout [URL]
    ) throws -> UserInput {
        var chatMessages: [Chat.Message] = []
        for message in request.messages {
            let (text, images, videos) = try parts(
                from: message.content, tempFiles: &tempFiles)
            switch message.role {
            case .user:
                chatMessages.append(.user(text, images: images, videos: videos))
            case .system:
                chatMessages.append(.system(text))
            case .assistant:
                chatMessages.append(.assistant(text))
            case .tool:
                chatMessages.append(.tool(text))
            }
        }
        return UserInput(chat: chatMessages)
    }

    /// Convenience overload that discards temp-file tracking. Used by
    /// tests that pass only base64/url images (no inline videos).
    static func buildUserInput(
        from request: OpenAIChatCompletionRequest
    ) throws -> UserInput {
        var sink: [URL] = []
        return try buildUserInput(from: request, tempFiles: &sink)
    }

    /// Split a message's content into the concatenated text plus decoded
    /// image/video media. Non-user roles drop media at the call site, but
    /// we still decode here so a malformed inline payload fails loudly
    /// rather than being silently ignored.
    private static func parts(
        from content: OpenAIMessageContent,
        tempFiles: inout [URL]
    ) throws -> (text: String, images: [UserInput.Image], videos: [UserInput.Video]) {
        switch content {
        case .text(let string):
            return (string, [], [])
        case .null:
            return ("", [], [])
        case .parts(let parts):
            var text = ""
            var images: [UserInput.Image] = []
            var videos: [UserInput.Video] = []
            for part in parts {
                switch part {
                case .text(let string):
                    text += string
                case .imageURL(let uri):
                    images.append(try decodeImage(uri))
                case .videoURL(let uri):
                    videos.append(try decodeVideo(uri, tempFiles: &tempFiles))
                case .unsupported:
                    continue
                }
            }
            return (text, images, videos)
        }
    }

    // MARK: - Media decode

    /// Decode an image content part. Inline `data:` URIs are decoded
    /// in-memory into a `CIImage`. Anything else is REJECTED: this is an
    /// end-to-end-encrypted provider, so the only legitimate transport for
    /// media is an inline `data:` URI inside the encrypted prompt. Accepting
    /// an arbitrary `http(s)://`/`file://` URL here would let a crafted
    /// request drive `CIImage(contentsOf:)` into an SSRF / local-file-read
    /// primitive (the provider is the fetcher), so a non-`data:` URI fails
    /// closed with `invalidURL`.
    static func decodeImage(_ uri: String) throws -> UserInput.Image {
        guard uri.hasPrefix("data:") else {
            throw MediaError.invalidURL(uri)
        }
        let data = try dataFromDataURI(uri)
        guard let image = CIImage(data: data) else {
            throw MediaError.imageDecodeFailed
        }
        return .ciImage(image)
    }

    /// Decode a video content part. Inline `data:` URIs are written to a
    /// unique temp file (tracked for cleanup) because AVFoundation consumes
    /// a URL. Anything else is REJECTED for the same reason as `decodeImage`:
    /// accepting an arbitrary `http(s)://`/`file://` URL would hand a crafted
    /// request an SSRF / local-file-read primitive via `AVAsset(url:)`. The
    /// only legitimate media transport on this E2E-encrypted provider is an
    /// inline `data:` URI, so a non-`data:` URI fails closed with `invalidURL`.
    static func decodeVideo(
        _ uri: String, tempFiles: inout [URL]
    ) throws -> UserInput.Video {
        guard uri.hasPrefix("data:") else {
            throw MediaError.invalidURL(uri)
        }
        let data = try dataFromDataURI(uri)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vlm-\(UUID().uuidString).mp4")
        do {
            try data.write(to: tempURL)
        } catch {
            throw MediaError.videoWriteFailed(String(describing: error))
        }
        tempFiles.append(tempURL)
        return .url(tempURL)
    }

    /// Extract the raw bytes from a `data:` URI. The header before the
    /// first comma decides the encoding: `;base64` ⇒ base64, otherwise
    /// the payload is percent-encoded UTF-8 text.
    static func dataFromDataURI(_ uri: String) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw MediaError.malformedDataURI("missing ','")
        }
        let header = uri[uri.startIndex..<commaIndex]
        let payload = String(uri[uri.index(after: commaIndex)...])

        if header.contains(";base64") {
            let stripped = payload.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: stripped) else {
                throw MediaError.base64DecodeFailed
            }
            return data
        }

        guard let decoded = payload.removingPercentEncoding,
            let data = decoded.data(using: .utf8)
        else {
            throw MediaError.percentDecodeFailed
        }
        return data
    }

    // MARK: - Stop-reason mapping

    /// Map a `GenerateStopReason` to the OpenAI `finish_reason` string.
    ///
    /// MLXLMServer ships an equivalent `GenerateStopReason.openAIFinishReason`
    /// but it is `internal` to that module, so we mirror its mapping here to
    /// keep the same wire contract as the batched + server engines: `.length`
    /// ⇒ `"length"`, everything else (`.stop`, `.cancelled`) ⇒ `"stop"`.
    static func openAIFinishReason(_ reason: GenerateStopReason) -> String {
        switch reason {
        case .length:
            return "length"
        case .stop, .cancelled:
            return "stop"
        }
    }
}
