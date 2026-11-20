### GPT-OSS tool calls follow Pydantic and zod schemas

- GPT-OSS `auto` tool calls are now held to a function's schema when it uses the shapes agent clients send every day: Pydantic's optional fields (`anyOf` with `null`), zod's root `$schema`, and value limits such as `minimum`, `maxLength` or `format`. The grammar enforces the structure, types, enums and required keys; a value limit it can't hold is left to the model. Before, such a function's arguments were sampled as generated.
- A function whose schema needs more (a union of several types, an allow-all `{}`) keeps its arguments as generated, as before.
- `DARKBLOOM_HARMONY_AUTO_TOOL_WIDEN=off` restores the previous behaviour.
