### Qwen forced tool calls open with the call

- On Qwen 3.6 35B, Qwen 3.5 9B and 35B and Qwen 3.8 27B, a request with `tool_choice` `"required"` or a named function could fail with 422 `tool_noncompliance`: the model was told to call, but nothing kept it from writing a sentence first, and any visible text before the call fails a forced call. On one Mac the provider now lets these models open the answer only with a call to a declared function (the named one, or any declared one for `required`); the arguments are still the model's own and are checked against the schema as before. The prompt is unchanged, and so are `auto`, `none` and the other models.
- A cluster pair, whose engine runs no constrained decoding, keeps the previous behavior, as does a request whose prompt leaves thinking on.
- `DARKBLOOM_QWEN_FORCED_TOOL_FRAMING=off` turns it off on a Mac (it also reaches a provider started by `darkbloom start`).
