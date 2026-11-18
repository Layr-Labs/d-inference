### GPT-OSS auto tool calls follow their schemas

- GPT-OSS `auto` tool calls are sampled under a grammar once a Harmony header names a function: only a declared function's name, then one JSON object of that function's schema (local `$ref`s inlined), then `<|call|>` once the object is complete. Reasoning, preambles and answers are sampled exactly as before, and the model still decides whether to call. A function whose schema the grammar cannot express, or whose prompt still shows a `$ref` typed as a string, keeps free arguments. Cluster pairs, native engines and a model whose logits width is not the vocabulary's are served without the grammar.
- A GPT-OSS `auto` call to an undeclared function that the grammar did not prevent is refused as a `strict` request refuses it (`undeclared_name`, 422), with or without `strict`, instead of being returned as a call.
- The local API inlines every GPT-OSS build's `$ref`s while the grammar is on, so its prompt matches the grammar.
- `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR=off` restores the previous behavior: no grammar, the previous local `$ref` list, and every call, an undeclared one included, returned as generated.
