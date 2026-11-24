### GPT-OSS tool parameters render as declared

GPT-OSS's Harmony template prints a tool parameter's `type` list as a union
(`string | integer`), a `oneOf` as the union of its members and a parameter
without a type as `any`. The schema repair that runs before every template
gave each such parameter one type, the first member's or `string`, so GPT-OSS
was told `string` for numbers, booleans, objects and `{}` and wrote strings,
or reasoned at length about the mismatch. GPT-OSS now renders each tool from
the request's own declaration and keeps the repair's type only where the
declaration states one type (an `Optional` field, an `enum`, an object or an
array). Other model families are unchanged, and a request whose tools arrive
already repaired renders exactly as before.

The prompt contract stays `darkbloom-request-normalization-v9`, which renders
the repaired types, so a coordinator request whose GPT-OSS tool render this
changes is served without the prompt cache, like requests whose tool-call
history carries a null. `darkbloom logs` notes each such request and the
daemon state counts them (`promptCacheSkippedToolRawSchema`).

The template utility (`/tokenize`) renders a body's tools as that body
declares them, for GPT-OSS and for Gemma 4's untyped properties. It therefore
shows the render of the caller's own declarations: a coordinator request
renders the same only once the coordinator forwards the caller's declarations
rather than the repaired ones.
