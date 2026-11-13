### Gemma 4 JSON answers follow the requested format

- A Gemma 4 26B request with a JSON `response_format` (`json_object`, or `json_schema` within the provider's supported subset) is now sampled under a grammar: after the model's thought, if any, the answer is exactly one JSON value of the requested format, with no code fences, surrounding prose or trailing text. A `json_schema` the grammar does not cover is held to a JSON object when its root is an object. The thought is unchanged.
- Requests the grammar does not cover (tools, `tool_choice`, `stop` sequences, images, other schemas) and cluster pairs are answered as before; an answer cut at `max_tokens` still ends as `length`, never as an error. `DARKBLOOM_GEMMA_JSON_ANSWERS=off` turns the grammar off on a Mac.
