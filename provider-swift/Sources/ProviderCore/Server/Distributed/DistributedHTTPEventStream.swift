import DarkbloomClusterProtocol
import Foundation
import Hummingbird
import MLXLMServer
import NIOCore

/// Distributed-only body writer. Existing solo response framing is unchanged.
/// The native profile already bounds generation; these are additional limits
/// on frames examined/written here, not a claim about upstream stream buffers.
/// A single writer sends a comment probe every 500 ms while awaiting output;
/// comments are never visible content, tokens or a refreshed request budget.
enum DistributedHTTPEventStream {
    static let maximumFrameBytes = 1_048_576
    // Budget framing as well as decoded text: 32K individual JSON/SSE deltas
    // can exceed the previous 8 MiB bound. This is a cumulative wire allowance,
    // not a buffer allocation; the pump and per-frame bounds remain unchanged.
    static let maximumStreamBytes = ClusterWorkerLimits.outputTokens * 2048 + maximumFrameBytes
    static let maximumTerminalBytes = 4_096
    enum Failure: Error, Equatable { case outputLimit, malformedFrame, missingTerminal }

    static func isVisibleContent(_ frame: String) throws -> Bool {
        guard frame.utf8.count <= maximumFrameBytes else { throw Failure.outputLimit }
        if frame == ServerSentEventEncoder.done { return false }
        guard frame.hasPrefix("data: "), frame.hasSuffix("\n\n"),
              let object = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).dropLast(2).utf8)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]] else { throw Failure.malformedFrame }
        // The product's rule for visible assistant output: content, reasoning
        // content or tool calls (`ProviderLoop.hasVisibleStreamOutput`).
        return choices.contains { choice in
            guard let delta = choice["delta"] as? [String: Any] else { return false }
            for key in ["content", "reasoning_content", "reasoning"] {
                if let text = delta[key] as? String, !text.isEmpty { return true }
            }
            if let calls = delta["tool_calls"] as? [Any], !calls.isEmpty { return true }
            return false
        }
    }

    /// The identity the product's chunks carry (`OpenAIChatCompletionChunk`),
    /// read from the first frame of this stream, so a failure frame written
    /// here names the same completion as every frame before it.
    struct ChunkIdentity: Equatable {
        let id: String
        let created: Int
        let model: String

        init?(frame: String) {
            guard frame.hasPrefix("data: "), frame.hasSuffix("\n\n"),
                  let chunk = try? JSONDecoder().decode(OpenAIChatCompletionChunk.self,
                                                        from: Data(frame.dropFirst(6).dropLast(2).utf8))
            else { return nil }
            id = chunk.id; created = chunk.created; model = chunk.model
        }
    }

    /// The product's own failure frame (`MLXOpenAIService` with
    /// `frameGenerationErrors`): a chunk whose finish reason is `error`.
    static func isProductFailureFrame(_ frame: String) -> Bool {
        guard frame.hasPrefix("data: "), frame.hasSuffix("\n\n"),
              let object = try? JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).dropLast(2).utf8)),
              let row = object as? [String: Any], row["error"] is [String: Any],
              let choices = row["choices"] as? [[String: Any]] else { return false }
        return choices.contains { $0["finish_reason"] as? String == "error" }
    }

    /// A failure the shared pipeline did not frame itself (a deadline, a
    /// clean stop the owner forced, an upstream that ended without a frame),
    /// in the product's failure-frame shape: the completion's chunk identity,
    /// one choice with an empty delta and `finish_reason: "error"`, and the
    /// error object. The cause and the attempt's usage ride along for the
    /// cluster's own diagnosis. Like the product's, nothing follows it.
    static func failureFrame(for response: DistributedHTTPResponse, upstreamFailed: Bool,
                             identity: ChunkIdentity? = nil) throws -> String? {
        guard let terminal = response.terminal else {
            // No actual native terminal means no reconciled usage or completion
            // can be asserted, even if an HTTP task or owner channel closed.
            throw Failure.missingTerminal
        }
        guard terminal.promptTokens >= 0, terminal.completionTokens >= 0 else { throw Failure.malformedFrame }
        let deadline = response.deadlineExpired || response.contentMissingAtTerminal
        let nativeFailure = terminal.cause != nil && terminal.cause != .cancelled
        guard deadline || nativeFailure || terminal.cause == .cancelled || upstreamFailed else { return nil }
        let reason = nativeFailure ? "inference_error" : deadline
            ? PreContentDeadlineFailure.deadlineUnreachable.rawValue : "inference_error"
        let cause = nativeFailure || !deadline ? terminal.cause?.rawValue : nil
        var error: [String: Any] = ["type": "server_error", "code": reason,
            "message": deadline && !nativeFailure ? "First visible content deadline was not met" : "Distributed generation did not complete"]
        if let cause { error["terminal_cause"] = cause }
        var object: [String: Any] = ["error": error, "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": ["content": ""], "finish_reason": "error"] as [String: Any]],
            "attempt_usage": ["prompt_tokens": terminal.promptTokens, "completion_tokens": terminal.completionTokens]]
        if let identity { object["id"] = identity.id; object["created"] = identity.created; object["model"] = identity.model }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let frame = "data: \(String(decoding: bytes, as: UTF8.self))\n\n"
        guard frame.utf8.count + ServerSentEventEncoder.done.utf8.count <= maximumTerminalBytes else { throw Failure.outputLimit }
        return frame
    }

    static func response(_ frames: AsyncThrowingStream<String, Error>, control: DistributedHTTPResponse) -> Response {
        let lifetime = DistributedHTTPBodyLifetime(control)
        // The product's event-stream headers (`LocalChatUploadResponder.sseResponse`).
        return Response(status: .ok, headers: [.contentType: "text/event-stream; charset=utf-8", .cacheControl: "no-cache"],
            body: .init { writer in
                defer { lifetime.completed() }
                do {
                    // The caller's isolation, named: SDKs with the `nonisolated(nonsending)` overload would otherwise
                    // pick it and send the non-Sendable writer into this helper.
                    try await withTaskCancellationHandler(operation: {
                        try await write(frames, control: control, writer: &writer)
                    }, onCancel: { control.disconnect() }, isolation: #isolation)
                } catch {
                    control.disconnect(); throw error
                }
            })
    }

    private static func write(_ frames: AsyncThrowingStream<String, Error>, control: DistributedHTTPResponse,
                              writer: inout any ResponseBodyWriter) async throws {
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: maximumFrameBytes)
        do {
            try await withTaskCancellationHandler(operation: {
                try await consume(pump, control: control, writer: &writer)
            }, onCancel: { _ = pump.cancel() }, isolation: #isolation)
        } catch {
            let producer = pump.cancel(); await producer?.value
            throw error
        }
        let producer = pump.cancel(); await producer?.value
    }

    private static func consume(_ pump: DistributedHTTPFramePump, control: DistributedHTTPResponse,
                                writer: inout any ResponseBodyWriter) async throws {
        let probe = ": keep-alive\n\n"
        var nextProbe = ContinuousClock.now.advanced(by: .milliseconds(500))
        var total = 0
        var writerFailed = false
        var upstreamFailed = false
        var trailing: [String] = []
        var identity: ChunkIdentity?
        do {
            readLoop: while true {
                try Task.checkCancellation()
                let item: DistributedHTTPFramePump.Item
                switch await pump.next(until: nextProbe) {
                case .item(let value): item = value
                case .closed: throw CancellationError()
                case .probe:
                    try Task.checkCancellation()
                    guard probe.utf8.count <= maximumStreamBytes - maximumTerminalBytes - total else { throw Failure.outputLimit }
                    total += probe.utf8.count
                    do { try await writer.write(ByteBuffer(string: probe)) }
                    catch { writerFailed = true; throw error }
                    nextProbe = ContinuousClock.now.advanced(by: .milliseconds(500))
                    continue
                }
                try Task.checkCancellation()
                let frame: String
                switch item {
                case .frame(let value): frame = value
                case .end: break readLoop
                case .failed(let error): throw error
                }
                let size = frame.utf8.count
                guard size <= maximumFrameBytes, size <= maximumStreamBytes - maximumTerminalBytes - total else {
                    control.disconnect(); throw Failure.outputLimit
                }
                total += size
                let visible = try isVisibleContent(frame)
                if identity == nil { identity = ChunkIdentity(frame: frame) }
                control.expire(at: ContinuousClock.now)
                // Defer final usage/finish/DONE until error disposition
                // is known. At most the existing finish frame + DONE.
                if frame == ServerSentEventEncoder.done || isFinishFrame(frame) {
                    guard trailing.count < 2 else { throw Failure.malformedFrame }
                    trailing.append(frame); continue
                }
                if control.deadlineExpired { continue }
                do { try await writer.write(ByteBuffer(string: frame)) }
                catch { writerFailed = true; throw error }
                if visible { control.contentAccepted() }
                nextProbe = ContinuousClock.now.advanced(by: .milliseconds(500))
            }
        } catch {
            if writerFailed || Task.isCancelled {
                control.disconnect(); throw error
            }
            if error is Failure { control.disconnect(); throw error }
            upstreamFailed = true
        }
        control.expire(at: ContinuousClock.now)
        if let failure = try failureFrame(for: control, upstreamFailed: upstreamFailed, identity: identity) {
            // When the shared pipeline framed the failure itself, the client
            // gets exactly the single-Mac endpoint's frame; either way the
            // stream ends there, as the product's does (no [DONE] after it).
            try await writer.write(ByteBuffer(string: trailing.first(where: isProductFailureFrame) ?? failure))
        } else {
            for frame in trailing { try await writer.write(ByteBuffer(string: frame)) }
        }
        try Task.checkCancellation()
        try await writer.finish(nil)
    }

    private static func isFinishFrame(_ frame: String) -> Bool {
        guard frame.hasPrefix("data: "), frame.hasSuffix("\n\n"),
              let object = try? JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).dropLast(2).utf8)),
              let row = object as? [String: Any], let choices = row["choices"] as? [[String: Any]] else { return false }
        return choices.contains { $0["finish_reason"] is String } || row["usage"] is [String: Any]
    }
}
