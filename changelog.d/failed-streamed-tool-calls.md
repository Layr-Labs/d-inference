### A streamed tool call that fails after it started is refused, never returned half-written

- A streamed `auto` tool call whose frame failed after its fragments started
  to leave (it did not parse, parsed differently from what had already left, or
  was still open when generation stopped before the token limit) used to be
  closed with only the arguments already sent, and the response finished
  `tool_calls`. Those arguments never parse, so no client could run the call,
  and OpenRouter counted it against the endpoint's tool-call success
  (InvalidJson).
- Such a call is now refused with its check (`tool_check` `malformed`,
  `diverged` or `unterminated`), `strict` or not: the client sees a failed
  response it can retry. A call the token limit cut still ends `length`, and
  calls that parse still return as generated, including those off their
  schema. `DARKBLOOM_REFUSE_FAILED_STREAMED_CALLS=0` (or `off`, `false`, `no`)
  restores the previous closing.
- Terminal profiles count the tool calls a response returned and how many of
  them break the request's declaration (`tool_calls`,
  `tool_calls_breaking_declaration`), counts only.
