### Inkling 2 Mini answers instead of failing when it writes a tool call nobody declared

- An Inkling 2 Mini request that declares no tools, but whose conversation describes a tool in text, could make the model write a native tool call anyway. The request then failed: a 422 when the call parsed, or a 500 when it did not, and a streaming client saw an error after the response had started.
- Such a call is now answer text: the client gets its JSON body as content, with no `tool_calls`, and client stop strings apply to it. Requests that declare tools, and `required`, named or `none` tool choices, are unchanged.
- `DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT=0` restores the refusal.
