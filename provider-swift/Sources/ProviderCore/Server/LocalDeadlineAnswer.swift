// A local request that reaches its overall deadline is answered busy, not as a failed generation.

import Foundation
import Hummingbird
import NIOCore

/// A local request's end at its overall deadline: the engine's safety ceiling on one Mac (or its legacy total wall,
/// `DARKBLOOM_CBV2_LEGACY_REQUEST_TIMEOUT`), and a pair's request deadline. The local API answers it as busy, in
/// `LocalMemoryRefusal.deadline` with code `capacity_busy`: a 503 with `Retry-After` before any SSE header, or, once
/// a stream has started, its failure event in those words (a chat or completions chunk, a Responses `response.failed`),
/// never "Response generation failed". It is this Mac's answer: the local router never passes it on, where it would
/// start over. The local router binds one per request it answers here, else `CORSResponder` does; the engine marks it
/// (`MultiModelBatchSchedulerEngine`, Nemotron Super's local route); a coordinator request has none and keeps its
/// typed terminal.
final class LocalDeadlineOutcome: @unchecked Sendable {
    @TaskLocal static var current: LocalDeadlineOutcome?

    private let lock = NSLock()
    private var isReached = false

    var reached: Bool { lock.withLock { isReached } }

    func markReached() { lock.withLock { isReached = true } }

    /// Whether an engine's typed end is the request's overall deadline.
    static func isDeadline(_ cause: InferenceTerminalCause) -> Bool {
        cause == .safetyDeadline
    }

    /// Whether an engine's untyped end is its legacy total wall (`CBv2TerminalCause.legacyRequestTimeout`).
    static func isLegacyDeadline(_ message: String) -> Bool {
        message.hasPrefix("request exceeded ") && message.hasSuffix("s deadline")
    }

    /// `body`, an SSE stream, with its failure event answered busy once the request reached its deadline. Each
    /// event is one write of the body (the local API's and the SDK's SSE writers).
    static func answeringBusy(_ body: ResponseBody, outcome: LocalDeadlineOutcome) -> ResponseBody {
        body.map { buffer in
            guard outcome.reached, let busy = busyFrame(replacing: String(buffer: buffer)) else { return buffer }
            return ByteBuffer(string: busy)
        }
    }

    /// A stream's failure event with its error in the busy words: the shared pipeline's chat or completions chunk
    /// (`finish_reason: "error"` and an error object), or a Responses `response.failed` event (its response's error).
    /// Nil for any other frame.
    static func busyFrame(replacing frame: String) -> String? {
        if DistributedHTTPEventStream.isProductFailureFrame(frame) {
            guard var row = object(frame.dropFirst(6).dropLast(2)) else { return nil }
            row["error"] = busyError
            return encoded(row).map { "data: \($0)\n\n" }
        }
        let failed = "event: response.failed\ndata: "
        guard frame.hasPrefix(failed), frame.hasSuffix("\n\n"), var event = object(frame.dropFirst(failed.count).dropLast(2)),
              var response = event["response"] as? [String: Any], response["error"] is [String: Any] else { return nil }
        response["error"] = ["code": InferenceErrorReason.capacityBusy.rawValue, "message": LocalMemoryRefusal.deadline]
        event["response"] = response
        return encoded(event).map { failed + $0 + "\n\n" }
    }

    /// The error object of the busy answer (a chunk's; the 503's body names the same words and code).
    static var busyError: [String: Any] {
        ["type": "server_error", "code": InferenceErrorReason.capacityBusy.rawValue, "message": LocalMemoryRefusal.deadline]
    }

    private static func object(_ json: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func encoded(_ object: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) }
    }
}
