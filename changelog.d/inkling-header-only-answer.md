### Inkling 2 Mini answers with text when it writes a header-only message

- An Inkling 2 Mini request that declares no tools, but whose system message describes a tool in text, could make the model answer with a message header and no content (for example `get_weather(city: Paris)` as the header). That text was dropped, so the client got an empty answer.
- The header's text is now the answer, and client stop strings apply to it. Requests that declare tools, and `none`, `required` or named tool choices, are unchanged.
- `DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT=0` restores the empty answer.
