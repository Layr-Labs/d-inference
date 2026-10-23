### Nemotron Super JSON response formats with tools

- Nemotron 3.5 Super now serves a `json_object` or `json_schema` response format in a request that also declares tools, instead of refusing it with 400. Tool calls are returned as `tool_calls`; an answer without calls must be valid JSON for the format, or the request fails with 422. A required or named `tool_choice` still needs its call.
