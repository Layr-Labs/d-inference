### More property names in structured JSON responses

- Response schemas can use property names containing spaces, punctuation,
  Unicode, quotes and backslashes, up to 256 UTF-8 bytes. The answer grammar
  generates one unambiguous JSON spelling per key. Tool declarations and
  tool argument names keep their existing rules.
- `DARKBLOOM_JSON_RESPONSE_PROPERTY_NAMES=off` restores the identifier-only
  response property rule.
