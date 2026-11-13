# Muse Glimmer prompt fixtures

| File | What it is | SHA-256 |
|---|---|---|
| `chat_template.jinja` | The chat template a served Muse Glimmer 30B artifact carries | `6e0a14fabecc8c547bd3cbb3937128f1a97f1c95a0c645ea228b457898f926a9` |
| `prompt-golden.json` | Reference prompts and token IDs, written by `scripts/muse-glimmer-qualification/prompt_golden.py` | regenerated; check with `--check` |
| `LICENSE` | Apache License 2.0, as the model repositories ship it | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |

## The served template

`chat_template.jinja` is Meta's template from
[`meta-models/Muse-Glimmer-30B`](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/cec94fcfd6512f2cfe708138c32533b346ea4f69/chat_template.jinja)
at revision `cec94fcfd6512f2cfe708138c32533b346ea4f69` (9,992 bytes, SHA-256
`cfc67e5f349f37690dfd31ed1f18bc4442a9dd32fe39a648f993cb4eb3cae678`) with one
change. Its default system block reads the date through

```jinja
{%- if current_date is defined and current_date -%}
    {{- '\nCurrent date: ' + current_date + '.' -}}
{%- elif strftime_now is defined -%}
    {{- '\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}
{%- endif -%}
```

and the served template replaces those five lines with the one direct call:

```jinja
{{- '\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}
```

`PromptRenderDate.supportsTemplate` accepts only direct literal date calls, so
the published file yields no prompt contract and no prefix cache. With a date
supplied, both files render every corpus case to the same text;
`prompt_golden.py --published` checks the derivation and that equality.

The NVIDIA NVFP4 repository ships Meta's older template (7,167 bytes). The
newer one differs in one error string and in the system message: it rewrites a
caller's "Reasoning effort" line to "Reasoning strength" and does not add a
second `Reasoning strength:` line when the system prompt already has one.

The template is Meta's, under the Apache License, Version 2.0 ([LICENSE](LICENSE)).
No weights, tokenizer or model code are in this directory.

## What the tests establish

`MuseGlimmerPromptGoldenTests` sends each corpus body through the production
request pipeline and renders the served template with the pinned Swift-Jinja,
the provider's template normalization and the model's `tojson` filter. The
text must equal the Python Jinja2 reference. With `MUSE_GLIMMER_NVFP4_DIR`
set, it also loads the real tokenizer and compares token IDs.

They do not establish model output quality, generation, or anything about the
weights. Image and video content parts are not in the corpus: this model's
media route is not served yet.
