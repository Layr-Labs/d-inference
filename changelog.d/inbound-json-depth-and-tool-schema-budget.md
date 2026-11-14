### Request JSON nesting limit and bounded tool-schema normalization

- A coordinator request or local API body that nests objects and arrays more
  than 64 deep is refused before any parser reads it (`malformed_body` on the
  coordinator path, HTTP 400 locally). Foundation's JSON parsers recurse once
  per level on the provider's 512 KiB task stacks, so a body of a few KB nested
  a few hundred levels deep crashed the provider (SIGBUS); the coordinator
  forwards such bodies unchanged. A body holding a NUL byte (UTF-16 or UTF-32,
  which those parsers also read but the depth scan cannot count) is refused the
  same way, and tool-call `arguments` nested past the limit are refused as
  `invalid_tool_arguments`. On the local API the limit covers every JSON route.
- Tool-schema normalization rewrites at most 100,000 schema nodes per request.
  Beyond that the body is decoded as sent, as one over 4 MiB already is, so a
  few MiB of `{}` schemas no longer expand into tens of MiB of rewritten JSON
  before the request is decoded.
