### Nemotron 3.5 Lightning: tool-call arguments follow the declared tools

- Lightning's `auto` tool calls are now sampled under the call grammar already used for strict Qwen 3.5-family calls,
  for every declared tool. A call can only name a declared function and its declared parameters, includes every
  required parameter, and writes enum values and the JSON types the schema allows. Reasoning and text stay free, and
  the model still decides whether to call.
- A parameter with an assertion the grammar cannot hold (for example a numeric bound or a string format) keeps its type,
  structure and enum values; only that assertion is left to the model. A parameter that still cannot be held is free
  text, read as before.
- The grammar admits only declared parameters, also where a schema leaves its object open. A tool that declares no
  parameters and stays open (`{"type": "object"}`) leaves its request unconstrained; `"properties": {}` is a tool that
  takes no arguments.
- The bare `<function=…>` frame that Lightning's parser also reads is held the same way.
- `DARKBLOOM_NEMOTRON_TOOL_GRAMMAR=off` restores unconstrained calls for Lightning. It is separate from
  `DARKBLOOM_STRICT_TOOL_GRAMMAR`, which keeps governing the Qwen 3.5-family builds only.
