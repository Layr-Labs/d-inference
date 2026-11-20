### A Qwen tool call the answer ends inside is closed instead of refused

- Qwen 3.5, 3.6 and 3.8 sometimes end their turn inside a tool call: after the last line of a long string argument,
  before `</parameter>`, `</function>` and `</tool_call>`. On long forced writes (a whole file through one call) this
  happened about 1 time in 10, and the call, though complete, was refused as `unterminated` after its arguments had
  already streamed. When generation ends on its own (not at the token limit) and the function is named, the provider
  now closes the frame and the call completes and is checked like any other, streamed or not. A frame that ends inside
  a tag is still refused.
- `DARKBLOOM_QWEN_CLOSE_OPEN_CALLS=0` (or `off`, `false`, `no`) restores the refusal. Telemetry
  `tool_call_closed_at_end` counts the calls closed this way.
