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
  `tool_calls_breaking_declaration`), counts only. The check approximates
  OpenRouter's: the provider's validator over the declared schema with local
  `$ref`s inlined.
- Qwen 3.5 XML calls (SDK mlx-swift-lm #446): a parameter typed through a
  union, a type list, `nullable` or a `$ref` streamed as a JSON string and then
  parsed as a number, Boolean, array or object, so the call failed as
  `diverged`. Such a parameter now streams once its value closes, in the form
  the complete parse reads. Qwen XML values also read a local `$ref` as the
  schema it names, so an object or array declared by reference is no longer
  returned as a string.
- The Qwen strict tool grammar (on by default for Qwen 3.6, Qwen 3.5 35B and
  Qwen 3.8 27B `strict` calls) declined a tool with a parameter the old
  streamer exposed as text but the parser converts, such as a
  `["integer","null"]` type list or a `{"type":"null"}` parameter. Streamed
  calls now agree with the parse, so such tools are constrained too.
