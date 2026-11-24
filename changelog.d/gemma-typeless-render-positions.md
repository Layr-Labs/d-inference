### Gemma 4 renders more untyped tool parameters as untyped

When the caller's tool declarations reach the provider as sent, Gemma 4 now
also shows these tool parameters untyped (`type:<|"|><|"|>`), as its template
renders a parameter without a type, instead of the `STRING` the schema repair
fills in:

- a parameter that is only a local `$ref` (`#/$defs/...` or
  `#/definitions/...`) to a schema with no type;
- an `anyOf` or `oneOf` whose members accept any value, a `null` member aside
  (it still renders `nullable`), and an `allOf` of such members;
- a typeless `enum` whose values have more than one JSON type, such as
  `["default", "inherit", "archive", -1]`. The template prints an enum only
  for a `STRING` parameter, which made Gemma quote `-1`.

A tuple parameter (`prefixItems` with `items` false or absent) no longer shows
the repair's `STRING` items. Every other parameter renders as before, and other
model families are unchanged. As for the untyped parameters already covered, a
coordinator request this changes is served without the prompt cache.
