### GPT-OSS honors `tool_choice` "required" and a named function

- A GPT-OSS 20B request with `tool_choice` `"required"` or `{"type": "function", "function": {"name": …}}` was refused (400 `tool_choice_unsupported` from the coordinator). It is now served: the model reasons first, at the request's `reasoning_effort`, then the provider lets it write only a call to a declared function (the named one, or any declared one for `required`), with arguments that match that function's schema. The reasoning arrives as `reasoning_content` and the call as `tool_calls`, with `finish_reason` `tool_calls`.
- One call per response: GPT-OSS's format ends the response at its first call, so `parallel_tool_calls` changes nothing.
- A named function that is not declared, or a schema outside the supported subset, is still a 400 before any generation. `auto` and `none` are unchanged.
- The Mac advertises the capability for `gpt-oss-20b`, and the coordinator routes these requests only to Macs on this release or later, never to a cluster pair. `DARKBLOOM_GPTOSS_FORCED_TOOLS=off` turns it off on a Mac (it also reaches a provider started by `darkbloom start`).
