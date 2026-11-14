# Muse Glimmer prompt fixtures

| File | What it is | SHA-256 |
|---|---|---|
| `chat_template.jinja` | The chat template a served Muse Glimmer 30B artifact carries | `0bb1b6209e797a62fdd81d445ddf36cbb1a2d71f84400c141c9ec11049d7ce3c` |
| `prompt-golden.json` | Reference prompts and token IDs, written by `scripts/muse-glimmer-qualification/prompt_golden.py` | regenerated; check with `--check` |
| `LICENSE` | Apache License 2.0, as the model repositories ship it | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` |

## The served template

`chat_template.jinja` is Meta's template from
[`meta-models/Muse-Glimmer-30B`](https://huggingface.co/meta-models/Muse-Glimmer-30B/blob/cec94fcfd6512f2cfe708138c32533b346ea4f69/chat_template.jinja)
at revision `cec94fcfd6512f2cfe708138c32533b346ea4f69` (9,992 bytes, SHA-256
`cfc67e5f349f37690dfd31ed1f18bc4442a9dd32fe39a648f993cb4eb3cae678`) with two
changes, neither of which changes a rendered byte (9,819 bytes).

First, its default system block reads the date through

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
the published file yields no prompt contract and no prefix cache.

Second, the tool-result branch passes a conditional as a call argument,
`namespace(name=tcid if tcid else '')`. The coordinator's prompt renderer
(minijinja) does not parse that spelling, and a template it cannot compile is
never planned for cache routing. The served template writes
`namespace(name=(tcid if tcid else ''))`, which Jinja2, Swift-Jinja and
minijinja all read the same way.

With a date supplied, both files render every corpus case to the same text;
`prompt_golden.py --published` checks the derivation and that equality. Both
sides hash these template bytes into the prompt contract id, so this file is
the canonical one.

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
