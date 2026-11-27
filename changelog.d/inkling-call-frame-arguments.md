### Inkling 2 tool calls in the OpenAI shape no longer fail

- An Inkling 2 tool call whose call frame used `arguments`, the OpenAI key, instead of the template's `args` was refused
  with a server error, so the answer broke off after its reasoning had already streamed. The provider now reads it as
  the tool call.
- A call frame that still does not parse is reported as the model's own tool-call error (422, `tool_noncompliance`)
  rather than a server error, so it no longer counts against the Mac that served it. A log line names which check the
  frame failed.
