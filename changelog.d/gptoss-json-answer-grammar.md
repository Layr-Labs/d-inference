### GPT-OSS JSON answers follow the requested format

- A GPT-OSS 20B request with a JSON `response_format` (`json_object`, or `json_schema` within the provider's supported subset) is now sampled under a grammar once the model finishes reasoning: the answer is exactly one JSON value of the requested format, with no code fences, surrounding prose or missing required keys. Reasoning is unchanged.
- Requests the grammar does not cover (tools, `tool_choice`, `stop` sequences, schemas outside the subset) are answered as before. `DARKBLOOM_GPTOSS_JSON_ANSWERS=off` turns the grammar off on a Mac.
