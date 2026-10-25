### GLM-5.3-Flash accepts OpenRouter's reasoning context and mode

GLM-5.3-Flash refused requests carrying OpenRouter's documented
`reasoning.context` or `reasoning.mode` with 400 `invalid_request`.
`reasoning.context` now chooses which returned reasoning the model sees:
`current_turn` keeps only the reasoning returned after the last user turn, as
`clear_thinking: true` does, while `all_turns` and `auto` keep every turn's.
`reasoning.mode: "standard"`, OpenRouter's default, is accepted. Other values,
`reasoning.mode: "pro"` and a context that contradicts `clear_thinking` are
still refused with 400.
