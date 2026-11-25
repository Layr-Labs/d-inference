### Inkling 2 Mini serves `tool_choice` `required` and named functions

- For `tool_choice` `required` or a named function, Inkling 2 now frames the
  call while sampling: after an optional thought it can only open a call to a
  declared function (the named one, for a named choice), with a JSON body
  that follows that function's parameter schema, then make another call when
  parallel calls are allowed, or finish. It can no longer answer in text, so
  these requests return a tool call instead of an error. Reasoning on and
  off, streamed and not. `auto` and `none` are unchanged. No rendered prompt
  changes.
- `DARKBLOOM_INKLING_FORCED_TOOLS`: `off`, `false`, `0`, `none`, `no` or
  `disabled` restores 0.10.18 (prompt-forced calls only).
