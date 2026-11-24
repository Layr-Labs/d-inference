### Inkling 2 Mini returns a call it writes as an answer message

- Inkling 2 Mini sometimes opens a text message where a tool call's header
  belongs (`<|content_text|>NAME<|content_invoke_tool_json|>{...}`). That call
  was returned as answer text, so the request had no call, or one call fewer
  in a parallel response. For a request that declares tools, such a message
  is now read as the call, with NAME held to the body's name as a header is.
- For those requests, the first characters of an answer that could still be a
  function name (up to 64 letters, digits, `_` or `-`) reach a streaming client
  together with the text that follows them.
