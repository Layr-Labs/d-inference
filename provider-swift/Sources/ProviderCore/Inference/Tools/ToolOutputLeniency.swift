// Copyright © 2026 Eigen Labs.

import Foundation

/// An answer the engine cut at its token limit (finish `length`) ends as a
/// normal `length` completion with its usage, instead of a
/// `tool_noncompliance` refusal or a native frame failure. The limit is the
/// request's `max_tokens` (or this Mac's clamp of it), not the model breaking
/// a contract, and a cut answer can never satisfy one; OpenAI-compatible
/// servers end it with `finish_reason: "length"`, and OpenRouter does not
/// count a call cut by the caller's `max_tokens` against the provider.
///
/// What already left stays as generated. A streamed call the end-of-stream
/// flush would complete stays open with the fragments it sent (the provider
/// closes nothing, so a client cannot parse and run a cut call), and the
/// stream finishes `length`; a withheld structured (`response_format`) answer
/// leaves as generated (GLM's normalized when it already holds a whole
/// value); withheld calls are checked one by one and those that fail are
/// dropped rather than refused, as is an unfinished frame. A loop the guard
/// stops, which also ends as `length`, counts as a cut. A call under
/// `tool_choice: none` is the model's and still refused
/// (`parallel_tool_calls: false` already keeps only the first call,
/// `ParallelToolCallPolicy`). A response with
/// calls that were complete before the cut still finishes `tool_calls`, as it
/// does today.
///
/// `DARKBLOOM_LENGTH_FINISH_AT_LIMIT`: unset or any other value keeps it on;
/// `0`, `off`, `false` or `no` restores the refusal. Read once per process.
enum TokenLimitCutPolicy {
    static let environmentKey = "DARKBLOOM_LENGTH_FINISH_AT_LIMIT"

    static let endsAtLength = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[environmentKey])
    }
}

/// A call to a `strict` function of an `auto` request whose client streams
/// leaves as generated, as a non-strict call does, when it fails this
/// provider's own check (schema, a declared name, arguments that parse)
/// after an event of the response has left. By then the client holds part of
/// the answer, so a refusal can only break the stream partway, which
/// OpenRouter counts as a failed response; a returned call is the client's
/// to check, as with any unconstrained server. Before anything left, and for
/// a client that does not stream, the refusal stays: it is a status the
/// router can still fail over on, and OpenRouter does not count it. Forced
/// choices and `parallel_tool_calls: false` keep their checks.
///
/// `DARKBLOOM_STRICT_CALLS_AS_GENERATED`: unset or any other value keeps it
/// on; `0`, `off`, `false` or `no` restores the refusal. Read once per process.
enum StrictToolCallPolicy {
    static let environmentKey = "DARKBLOOM_STRICT_CALLS_AS_GENERATED"

    static let returnsAsGenerated = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[environmentKey])
    }
}

/// A streamed call that fails after its fragments started to leave (its
/// frame does not parse, parses differently from what already left, or is
/// still open when generation stops before the token limit) is refused with
/// its `tool_check`, never closed as a finished call. Its arguments are only
/// the part already sent, so no client can run it: a `tool_calls` finish
/// with arguments that do not parse is what OpenRouter's validator counts
/// against the endpoint (InvalidJson), and the coordinator refuses the next
/// turn whose history carries them (`tool_arguments_not_object`). A refused
/// response is a failed response, which the client can retry. A call the
/// token limit cut still ends `length` (`TokenLimitCutPolicy`), and calls
/// that parse still return as generated.
///
/// `DARKBLOOM_REFUSE_FAILED_STREAMED_CALLS`: unset or any other value keeps it
/// on; `0`, `off`, `false` or `no` restores closing such a call with the
/// arguments it sent (`auto` without `strict`, or `strict` once the response
/// started). Read once per process.
enum FailedStreamedCallPolicy {
    static let environmentKey = "DARKBLOOM_REFUSE_FAILED_STREAMED_CALLS"

    static let refuses = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[environmentKey])
    }
}

/// The off words of the tool-output switches, trimmed and in any case: `0`,
/// `off`, `false`, `no`. Unset or anything else is on.
enum ToolOutputLeniencySwitch {
    static func isOff(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["0", "off", "false", "no"].contains(value)
    }
}
