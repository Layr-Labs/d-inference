### More property names in structured JSON responses

- With `DARKBLOOM_JSON_RESPONSE_PROPERTY_NAMES=1`, response schemas can use property names containing spaces, punctuation,
  Unicode, quotes and backslashes, up to 256 UTF-8 bytes. The answer grammar
  generates one unambiguous JSON spelling per key. Tool declarations and
  tool argument names keep their existing rules.
- Unset or unrecognized values keep the identifier-only rule. Local debug
  errors report bounded failure codes and HTTP status, not request text.
