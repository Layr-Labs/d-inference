# Flint template replay fixture

`chat_template.jinja` and `LICENSE` are unmodified copies from Recursive's
[`RecursiveSI/flint-int4` release](https://huggingface.co/RecursiveSI/flint-int4/tree/3b93f9053b530488405ae9fca51d4900d6ce21f0),
at immutable revision `3b93f9053b530488405ae9fca51d4900d6ce21f0`.
They were copied from the locally downloaded `models/flint-int4` artifact.

| File | Immutable upstream source | SHA-256 |
|---|---|---|
| `chat_template.jinja` | [Template](https://huggingface.co/RecursiveSI/flint-int4/blob/3b93f9053b530488405ae9fca51d4900d6ce21f0/chat_template.jinja) | `7940f4ffa3275c36caa4a582f845aaad79da11018b3961e8fbcad6ae29733466` |
| `LICENSE` | [License](https://huggingface.co/RecursiveSI/flint-int4/blob/3b93f9053b530488405ae9fca51d4900d6ce21f0/LICENSE) | `43070e2d4e532684de521b885f385d0841030efa2b1a20bafb76133a5e1379c1` |

The template is attributed to Recursive and distributed under the Apache
License, Version 2.0. The full upstream license is retained in [LICENSE](LICENSE).
No weights or model runtime code are included in this fixture.

`FlintTemplateReplayTests` loads these files through the test target's existing
`.copy("Fixtures")` resource declaration and verifies both hashes. It sends a
typed OpenAI request through `ToolChoicePromptPolicy.prepare` and
`ProviderPromptContractPipeline.normalizedInput`, then renders this complete
template with the actual Swift Jinja engine and tokenizer compilation options.
The regressions cover historical null argument keys, nested nulls and array
positions, raw-string whitespace, and null schema defaults/enums carried by
the SDK's private `JSONNull` sentinel from `toolSpec()`.

The other-architecture cases use this template only to inspect the unchanged
generic sanitizer output. They do not claim other models serve Flint's template.
These tests establish template replay behavior, not model generation quality,
tokenization parity, or GPU qualification. The pinned template has no escape
for a literal `</arg_value>` in a top-level raw string; these fixtures do not
claim such strings universally round-trip.
