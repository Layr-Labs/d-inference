# GLM-5.3-Flash prompt fixtures

These are exact official-template rendering fixtures, not a model registration,
raw-candidate repair, tokenizer comparison or native inference qualification.

- `chat_template.jinja` is the unchanged 10,950-byte official source from
  `zai-org/GLM-5.3-Flash@91b69215804f2d2036a8867f6ce44848e278dcda`.
- `LICENSE` retains the upstream MIT notice.
- `metadata.json` separates official template identity from the differing raw
  Vontra 4-bit MTP template. Neither snapshot is rewritten automatically.
- `goldens.json` contains complete rendered UTF-8 strings and their SHA-256
  hashes. Reference generation used local Jinja2 3.1.6 with sorted object inputs
  and compact sorted-key `tojson`, matching the native renderer's conventions.

The fixtures distinguish effort (`low`, `high`, `max`, default `max`) from
`clear_thinking` (default `false`). Clearing only suppresses earlier historical
reasoning; it does not disable newly generated reasoning or the prompt's open
`<think>` suffix. Binary thinking controls are not aliases for this operation.

Provider tests exercise the real shared pipeline and local chat decoder against
all seven renders. The Rust-sidecar opt-in test accepts
`GLM53_PROMPT_FIXTURE_DIR` pointing here and exercises its actual GLM normalizer
and renderer against the same corpus. These source tests still require execution
in the parent-controlled build lane; the recorded Jinja2 reference pass alone is
not Swift/Rust parity evidence.

The GLM text path preserves raw schemas and nulls after trusted model-type
selection. Media still requires a verified native wrapper; the reasoning-control
resolver itself has no unconditional family-wide media prohibition. Strict tool
decoding, forced tool choice and JSON output modes remain explicit refusals until
their real enforcement is qualified.
