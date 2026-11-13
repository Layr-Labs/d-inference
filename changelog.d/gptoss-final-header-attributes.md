### GPT-OSS answers under a `final` header with attributes reach the client

- GPT-OSS can open its answer with Harmony header attributes, as in `<|channel|>final <|constrain|>json<|message|>`, typically for JSON answers. The provider's Harmony split kept only an exact `final` header, so such an answer was dropped and the client got empty `content`. It now arrives as `content`, as any other answer does.
- Nothing else in a GPT-OSS response changes: reasoning, tool calls, preambles and plain answers are byte-identical.
