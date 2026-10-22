### The local Responses API continues a conversation from `previous_response_id`

- `/v1/responses` on a single Mac and on a cluster now honours `previous_response_id`: the request continues the earlier input and that response's output, as with OpenAI. A follow-up that sends only a `function_call_output` item resolves its tool call instead of failing with 400, and a later turn remembers earlier ones.
- An ID this process does not hold (never served, sent with `"store": false`, dropped from the bounded in-memory store, or from before a restart) returns 400 with code `previous_response_not_found`.
