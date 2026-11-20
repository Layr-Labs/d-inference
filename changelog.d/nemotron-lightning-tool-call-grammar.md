### Nemotron 3.5 Lightning: tool-call arguments follow the declared tools

- Lightning's `auto` tool calls are now sampled under the call grammar already used for strict Qwen 3.5-family calls,
  for every declared tool. A call can only name a declared function and its declared parameters, includes every
  required parameter, and writes enum values and the JSON types the schema allows. Reasoning and text stay free, and
  the model still decides whether to call.
- A parameter whose schema the grammar cannot hold exactly (for example a numeric bound or a string format) is written
  as free text and read as before; the function and parameter names are still held.
- The bare `<function=…>` frame that Lightning's parser also reads is held the same way.
- `DARKBLOOM_NEMOTRON_TOOL_GRAMMAR=off` restores unconstrained calls.
