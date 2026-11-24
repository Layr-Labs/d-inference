### Gemma 4 tool parameters typed as a string-first union render their typed member

A tool parameter declared as a union of `string` and one other scalar type,
for example `{"type": ["string", "integer"]}` or an `anyOf` / `oneOf` of the
two, was shown to Gemma 4 as `STRING`: its template prints a single type and
never the union, and the schema repair picked the first member. Gemma then
quoted typed values (`"-4200"` for `-4200`). Gemma 4 now sees the other member
(`INTEGER`, `NUMBER` or `BOOLEAN`); a `null` member still renders as
`nullable`. The union itself stays in the request, so validation accepts both
members as before. Unions with more members, other types or an `enum` keep
`STRING`, and other model families are unchanged.

The prompt contract stays `darkbloom-request-normalization-v9`, which still
renders `STRING`, so a coordinator request whose Gemma tool declaration this
changes is served without the prompt cache, like requests whose tool-call
history carries a null. `darkbloom logs` notes each such request and the
daemon state counts them (`promptCacheSkippedToolUnionType`).
