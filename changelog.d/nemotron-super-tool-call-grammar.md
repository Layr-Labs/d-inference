### Nemotron 3.5 Super: tool-call arguments follow the declared tools, with or without images

- Super's `auto` tool calls are now sampled under the call grammar Lightning uses, for every declared tool, on text,
  image and video requests. A call can only name a declared function and its declared parameters, includes every
  required parameter, and writes enum values and the JSON types the schema allows. Reasoning and text stay free, and
  the model still decides whether to call.
- A parameter with an assertion the grammar cannot hold (for example a numeric bound or a string format) keeps its type,
  structure and enum values; only that assertion is left to the model.
- Requests with a reasoning budget (`reasoning.max_tokens`), forced tool choices and requests the grammar cannot hold
  are served as before.
- `DARKBLOOM_NEMOTRON_SUPER_TOOL_GRAMMAR=off` restores unconstrained calls for Super. It is separate from
  `DARKBLOOM_NEMOTRON_TOOL_GRAMMAR`, which governs Lightning.
