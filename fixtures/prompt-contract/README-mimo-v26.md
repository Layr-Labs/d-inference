# MiMo V2.6 synthetic prompt corpus

`mimo-v26-additional20.json` is the unchanged project-authored, synthetic
20-case normalization/render/tokenizer oracle. It contains no operator prompts,
credentials, machine paths or endpoints. Its model label is synthetic.

The expected rendering and token IDs derive from public Xiaomi MiMo metadata:
`XiaomiMiMo/MiMo-V2.6-Flash-RL` at
`5711b268169967567844e1e560e8a3966da959b1`. The upstream model card declares MIT;
attribution remains with the Xiaomi MiMo Team. The setup script fetches only
four immutable metadata files with exact SHA-256 checks, never weights or code.

Corpus SHA-256:
`66e6a49a23509fbc99e5389fa4687f2b6175f96d05d7a8be0f323bf4986049bb`.
Do not regenerate, reorder or silently rebaseline these expectations.

This is the original public-source parser/planner regression, not proof for a
different serving artifact or full-model inference. See the repository's
[reproduction instructions](../../docs/developer/mimo-prompt-fixtures.md).
