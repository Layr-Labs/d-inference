### Gemma reasons with `tool_choice` `none`

- A Gemma 4 request with `tool_choice` `none` and reasoning on could not open its thought: the sampler that keeps tool calls out also masked Gemma's reasoning delimiters, `<|channel>` and `<channel|>`. Such a request now reasons and answers as it does without `tool_choice`; before, it could repeat until it hit its output limit. Tool-call markers stay refused, and required or named `tool_choice` is unchanged.
