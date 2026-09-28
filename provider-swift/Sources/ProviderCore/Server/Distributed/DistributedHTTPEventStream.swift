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
    static let maximumStreamBytes = 8_388_608
    static let maximumTerminalBytes = 4_096
    enum Failure: Error, Equatable { case outputLimit, malformedFrame, missingTerminal }

    static func isVisibleContent(_ frame: String) throws -> Bool {
        guard frame.utf8.count <= maximumFrameBytes else { throw Failure.outputLimit }
        if frame == ServerSentEventEncoder.done { return false }
        guard frame.hasPrefix("data: "), frame.hasSuffix("\n\n"),
              let object = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).dropLast(2).utf8)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]] else { throw Failure.malformedFrame }
        return choices.contains { choice in
            guard let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String else { return false }
            return !content.isEmpty
        }
    }

    static func failureFrame(for response: DistributedHTTPResponse, upstreamFailed: Bool) throws -> String? {
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
        let bytes = try JSONSerialization.data(withJSONObject: ["error": error,
            "attempt_usage": ["prompt_tokens": terminal.promptTokens, "completion_tokens": terminal.completionTokens]],
            options: [.sortedKeys, .withoutEscapingSlashes])
        let frame = "data: \(String(decoding: bytes, as: UTF8.self))\n\n"
        guard frame.utf8.count + ServerSentEventEncoder.done.utf8.count <= maximumTerminalBytes else { throw Failure.outputLimit }
        return frame
    }

    static func response(_ frames: AsyncThrowingStream<String, Error>, control: DistributedHTTPResponse) -> Response {
        let lifetime = DistributedHTTPBodyLifetime(control)
        return Response(status: .ok, headers: [.contentType: "text/event-stream; charset=utf-8", .cacheControl: "no-store"],
            body: .init { writer in
                defer { lifetime.completed() }
                do {
                    try await withTaskCancellationHandler {
                        try await write(frames, control: control, writer: &writer)
                    } onCancel: { control.disconnect() }
                } catch {
                    control.disconnect(); throw error
                }
            })
    }

    private static func write(_ frames: AsyncThrowingStream<String, Error>, control: DistributedHTTPResponse,
                              writer: inout any ResponseBodyWriter) async throws {
        let pump = DistributedHTTPFramePump(frames, maximumFrameBytes: maximumFrameBytes)
        do {
            try await withTaskCancellationHandler {
                try await consume(pump, control: control, writer: &writer)
            } onCancel: { _ = pump.cancel() }
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
        if let failure = try failureFrame(for: control, upstreamFailed: upstreamFailed) {
            try await writer.write(ByteBuffer(string: failure))
            try await writer.write(ByteBuffer(string: ServerSentEventEncoder.done))
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
