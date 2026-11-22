### Qwen finishes a tool call it started instead of ending its turn inside it

- Qwen 3.5, 3.6 and 3.8 sometimes ended their turn inside a tool call, right after the last line of a long string
  argument and before the closing tags; on long forced writes this happened about 1 time in 10, and the call was refused
  after its arguments had streamed. For requests whose `tool_choice` is `required` or a named function, the provider
  now samples so that no end of turn is possible while a call is open: the model writes the rest of the value and
  closes the call itself. The token limit still ends an answer as `length`, and `auto` requests are unchanged. Such
  forced requests give up speculative drafting, about 8 % slower single-request decode on Qwen 3.6.
- `DARKBLOOM_QWEN_CALL_END_GUARD=0` (or `off`, `false`, `no`) turns it off.
