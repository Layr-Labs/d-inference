### GLM-5.3-Flash serves structured-output schemas from pydantic, zod and OpenAI strict mode

A GLM-5.3-Flash `response_format` `json_schema` that used keywords outside the
subset Flint compiles into a grammar, such as `$defs` and `$ref`, `anyOf`
nullable fields, `format`, `pattern`, numeric bounds, `maxItems` or an untyped
property, was refused with HTTP 400 before generation. GLM compiles no grammar,
so these requests are now served as on the other families: the schema steers
the answer, which is withheld until it satisfies the caller's schema and is a
422 with no content otherwise.
