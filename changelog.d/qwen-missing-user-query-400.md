### Qwen and Bonsai histories without a user query are a client error

Qwen 3.5, 3.6 and 3.8 and Ternary Bonsai 2 requests whose history has no user
turn beyond `<tool_response>` wrappers (for example only a system message, or
system plus assistant) now fail before rendering with a typed HTTP 400. They
previously reached the template's "No user query found in messages." raise
and surfaced as a provider 500 `template_render` failure.
