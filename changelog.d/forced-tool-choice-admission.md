### Forced tool calls on Qwen 3.5, Qwen 3.6 and MiMo

- Qwen3.5-9B, Qwen3.5-35B-A3B, Qwen3.6-35B-A3B and MiMo-V2.6-Flash now
  advertise `tool_choice` `required` and named-function support, so the
  coordinator routes those requests to them instead of rejecting them with
  HTTP 400. Calls stay withheld until they parse and match the declared
  schema.
- A forced call on Qwen 3.5-family models (including Qwen3.8-27B) no longer
  fails when the model writes a newline between parallel calls or around a
  call. Any other text still fails the request.
