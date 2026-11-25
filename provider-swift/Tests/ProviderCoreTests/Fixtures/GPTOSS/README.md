# GPT-OSS chat template fixture

`chat_template.jinja` and `LICENSE` are unmodified copies from OpenAI's
[`openai/gpt-oss-20b` release](https://huggingface.co/openai/gpt-oss-20b/tree/6cee5e81ee83917806bbde320786a8fb61efebee),
at immutable revision `6cee5e81ee83917806bbde320786a8fb61efebee`. The served
`mlx-community/gpt-oss-20b-MXFP4-Q8` model, at revision
`773a7da77e569019bb0fd17a554b263738d669a3`, carries a byte-identical template.

| File | Immutable upstream source | SHA-256 |
|---|---|---|
| `chat_template.jinja` | [Template](https://huggingface.co/openai/gpt-oss-20b/blob/6cee5e81ee83917806bbde320786a8fb61efebee/chat_template.jinja) | `a4c9919cbbd4acdd51ccffe22da049264b1b73e59055fa58811a99efbd7c8146` |
| `LICENSE` | [License](https://huggingface.co/openai/gpt-oss-20b/blob/6cee5e81ee83917806bbde320786a8fb61efebee/LICENSE) | `58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd` |

The template is attributed to OpenAI and distributed under the Apache License,
Version 2.0. The full upstream license is retained in [LICENSE](LICENSE). No
weights or model runtime code are included in this fixture.

`TemplateRenderStackTests` loads the template through the test target's existing
`.copy("Fixtures")` resource declaration and verifies its hash. It renders a
tool schema nested 64 levels deep, the most a request may carry, on the render
stack (`TemplateRenderStack`). Its `render_typescript_type` macro needs the most
stack per schema level of the served templates.

`tool-schema-corpus.json` is ours: the 1,336 distinct `function.parameters`
objects of a realistic tool-call schema test corpus (type lists, `anyOf` /
`oneOf` / `allOf`, `{}`, boolean schemas, `enum` / `const`, `$ref`, nested
objects and arrays), with each string `description` and `title` replaced by
`d`. `GPTOSSToolSchemaRenderTests` renders every one through the template above
as the ingress repair forwards it and checks the render is unchanged.
