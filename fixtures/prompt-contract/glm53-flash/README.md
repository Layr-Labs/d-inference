# GLM-5.3-Flash prompt fixtures

These are exact official-template rendering fixtures, not a model registration,
raw-candidate repair, tokenizer comparison or native inference qualification.

- `chat_template.jinja` is the unchanged 10,950-byte official source from
  `zai-org/GLM-5.3-Flash@91b69215804f2d2036a8867f6ce44848e278dcda`. It remains
  the rendering authority for `goldens.json`.
- `eigenlabs-chat_template.jinja` is the 10,954-byte template shipped in the
  `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp` artifact. It replaces the official
  source's four numeric attribute accesses (`m.content.0.type`,
  `tr.output.0.type`, `m.content.0.output`, `entry.output.0.type`) with `[0]`
  subscripts. The pinned Swift-Jinja 2.3.6 renderer cannot parse the official
  spelling, so the provider accepts only this artifact template.
- `LICENSE` retains the upstream MIT notice for both templates.
- `metadata.json` separates the official template, the shipped artifact
  template and the differing raw Vontra 4-bit MTP template. None of these
  snapshots is rewritten automatically.
- `goldens.json` contains complete rendered UTF-8 strings and their SHA-256
  hashes. Reference generation used local Jinja2 3.1.6 with sorted object inputs
  and compact sorted-key `tojson`, matching the native renderer's conventions.

The artifact template is equivalent, not merely similar: Jinja2 3.1.6 compiles
both templates to byte-identical Python code, and both render every golden
identically. The provider must render the artifact template with the unpatched
pinned Swift-Jinja and match each golden byte for byte. The platform sidecar
must render both templates identically to the same goldens.

The fixtures distinguish effort (`low`, `high`, `max`, default `max`) from
`clear_thinking` (default `false`). Clearing only suppresses earlier historical
reasoning; it does not disable newly generated reasoning or the prompt's open
`<think>` suffix. Binary thinking controls are not aliases for this operation.

Provider tests exercise the real shared pipeline and local chat decoder against
all seven renders. The platform's Rust sidecar vendors byte-identical copies of
both templates, `goldens.json` and `LICENSE` under
`coordinator/promptsidecar/tests/fixtures/glm53-flash/` and always exercises its
actual GLM normalizer and renderer against them; update both copies together.
These source tests still require execution
in the parent-controlled build lane; the recorded Jinja2 reference pass alone is
not Swift/Rust parity evidence.

The GLM text path preserves raw schemas and nulls after trusted model-type
selection. Media still requires a verified native wrapper; the reasoning-control
resolver itself has no unconditional family-wide media prohibition. Strict tool
decoding, forced tool choice and JSON output modes remain explicit refusals until
their real enforcement is qualified.

The `metadata.json` `claims` flags describe only what this fixture corpus proves.
In particular, `media: false` means these vectors do not qualify media rendering
or execution; it is not a runtime GLM media-support prohibition. Runtime support
is governed by the managed native wrapper and its independently qualified gates.

`additional-goldens.json` covers the `minimal` → `low`, `medium` → `high` and
`xhigh` → `max` effort aliases through provider normalization, plus an image
marker through the shipped renderer alone. The image case does not fetch or
process media and does not qualify native vision. Jinja2 3.1.6 renders the pinned
official and shipped sources identically for these four cases.
