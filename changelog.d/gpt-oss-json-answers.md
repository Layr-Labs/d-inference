### GPT-OSS JSON answers follow the requested format

- A GPT-OSS request with a JSON `response_format` (and no tools) now gets an answer held to that format while it is generated: the model reasons as before, then its final message is one JSON value of the schema, or one JSON object for `json_object`. Schemas in the Pydantic, OpenAI strict and zod shapes are constrained too; a value limit the grammar can't hold (`minimum`, `pattern`, `format`, …) is left to the model. Before, the format was only requested in the prompt.
- With a small `max_tokens`, the reasoning now ends early to keep half the output (64 to 256 tokens) for the answer, so the answer is complete more often.
- Nothing is refused for it: a request the grammar can't serve (a cluster pair, a schema it can't express) is answered as before.
- `DARKBLOOM_HARMONY_JSON_ANSWERS=off` restores the previous behaviour.
