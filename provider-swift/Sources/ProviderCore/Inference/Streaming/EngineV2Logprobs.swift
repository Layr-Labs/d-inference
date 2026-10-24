// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Captured metadata uses the canonical SDK schema and ordered event stream.
public typealias SSETokenLogprob = OpenAITokenLogprob

extension OpenAITokenLogprob {
    /// JSONSerialization-compatible dictionary in the exact OpenAI wire
    /// shape, retained for callers of the generic frame injector.
    var jsonObject: [String: Any] {
        [
            "token": token,
            "logprob": Double(logprob),
            "bytes": bytes ?? [],
            "top_logprobs": topLogprobs.map { top in
                [
                    "token": top.token,
                    "logprob": Double(top.logprob),
                    "bytes": top.bytes ?? [],
                ] as [String: Any]
            },
        ]
    }
}

/// Present only when the raw request asks for logprobs. The scheduler applies
/// the requested alternative limit before forwarding metadata in stream order.
public struct EngineV2LogprobsPlumbing: Sendable {
    public let topLogprobs: Int?

    public init(topLogprobs: Int?) {
        self.topLogprobs = topLogprobs
    }

    func requested(_ entries: [SSETokenLogprob]) -> [SSETokenLogprob] {
        let limit = max(0, topLogprobs ?? 0)
        return entries.map {
            .init(token: $0.token, logprob: $0.logprob, bytes: $0.bytes,
                  topLogprobs: Array($0.topLogprobs.prefix(limit)))
        }
    }
}
