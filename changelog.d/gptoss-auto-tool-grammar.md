### GPT-OSS auto tool calls follow their schemas

- GPT-OSS `auto` tool calls are sampled under a grammar once a Harmony header names a function: only a declared function's name, then one JSON object of that function's schema (local `$ref`s inlined), then `<|call|>` once the object is complete. Reasoning, preambles and answers are sampled exactly as before, and the model still decides whether to call. A function whose schema the grammar cannot express keeps free arguments; cluster pairs are unchanged.
- A GPT-OSS `auto` call to an undeclared function is no longer returned as a call; its frame is text, as on Qwen.
- The local API inlines `gpt-oss-20b`'s `$ref`s while the grammar is on, so its prompt matches the grammar.
- `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR=off` restores calls as generated.
