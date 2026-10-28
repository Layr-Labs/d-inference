# Registered Qwen 27B output-gate source audit

Date: 2026-09-14. Source and retained metadata only. No model construction, tensor
evaluation, new weight/header download, SSH, eligibility change or repository edit.

**The existing provider does not read `output_gate_type`. Its actual Gated DeltaNet
output gate already uses SiLU, which is compatible at the operator level with the
registered `swish` value and the pinned primary reference. No change to the
full-attention sigmoid gate is justified.** The gate-specific adaptation is explicit
supported-value validation and metadata admission, followed by numerical qualification;
it is not a new activation implementation. This does not establish 27B/M3 capability.

## Exact artifact and primary-source pins

The retained artifact is `EigenLabs/Qwen3.8-27B-4bit-mtp`, version `2026-09-03-r1`,
declared aggregate `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`.
Its 4,441-byte config matches its retained manifest entry and SHA-256
`4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff`. This verifies the
small configuration file against the retained manifest; it does not verify model
payloads or the claimed aggregate's contents.

The [official Qwen config at revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`](https://huggingface.co/Qwen/Qwen3.8-27B/blob/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/config.json)
has an exactly equal parsed `text_config`, including `output_gate_type: swish`,
`hidden_act: silu` and `attn_output_gate: true`. The official raw file is 4,312 bytes,
SHA-256 `191e0af232104ed8b65258cf3fb2b842e288008baca7633c11b82a1ac7203aab`.
The registered file adds conversion/generation/MTP metadata at the root.

The saved catalog declares a different Hub revision,
`06d517d395dfc5588090f7f534112bee331f7b4a`; its official config URL returned HTTP 404
in this audit. The successfully retrieved revision is an independently matching
configuration, not proof of that unavailable revision or the weight conversion's
origin. The failed attempt is retained separately.

Transformers tag `v5.8.0` resolves through annotated tag
`a9e70365af64e028d40d8c7909deb7f138b49857` to commit
`049d2bf1220747b6d39e2a978b9f5fe0defa1dca`. The tag object, raw configuration/model/
activation sources and fetch hashes are retained. The artifact says `5.8.0.dev0`,
which does not specify the exact training/export code commit; the release pin is
a source reference, not an asserted match to that unspecified development build.

## The operation, and what the property currently controls

In the pinned [Transformers model](https://github.com/huggingface/transformers/blob/049d2bf1220747b6d39e2a978b9f5fe0defa1dca/src/transformers/models/qwen3_5/modeling_qwen3_5.py#L175),
the GDN fallback normalizes recurrent output before multiplying by `SiLU(z)` and
casting back to the input dtype. Its forward path applies that gated norm before
`out_proj` (lines 537–543). The optional fused norm receives `hidden_act`, which is
`silu` for this artifact. Full attention separately multiplies its result by a
sigmoid gate before `o_proj` (lines 699–702). These are two different gates.

Neither that model nor its [configuration class](https://github.com/huggingface/transformers/blob/049d2bf1220747b6d39e2a978b9f5fe0defa1dca/src/transformers/models/qwen3_5/configuration_qwen3_5.py#L25)
reads `output_gate_type`. The provider's `Qwen35TextConfiguration` likewise has no
property, CodingKey or decode for it. Thus changing this field alone does not
select a different operation in the inspected implementations. The primary
[activation registry](https://github.com/huggingface/transformers/blob/049d2bf1220747b6d39e2a978b9f5fe0defa1dca/src/transformers/activations.py#L93)
maps both SiLU and Swish spellings to SiLU implementations: `z * sigmoid(z)`.

The retained earlier `qwen38-output-gate-and-eligibility-audit-20260913.json` reports
that vLLM explicitly maps this field to GDN `RMSNormGated`, normalizes `swish` to
`silu` and uses normalization before gating. That audit cited mutable vLLM `main`
without a source commit/content archive. It is retained as historical attribution,
not upgraded to a newly verified immutable selector contract here. This task's
fresh network sources were limited to official Qwen/Transformers sources.

The strongest new conclusion is therefore precise: the registered value agrees
with the actual primary-reference GDN operation, and current Swift performs that
operation; configurable dispatch for this property is absent. Alternate property
values are not qualified by this audit.

## Existing Swift and stored parameter geometry

The inspected library HEAD is `ce446cc5f76e013855fe0bde9002b6db1ac091b7`; repository
HEAD is `e4df336bc8399f4fd0a46d1207b594d2514f14f5`. Exact inspected source bytes are
pinned and copied into `local-source-archive`; those bytes, rather than an assumption
of a clean worktree, bind this audit.

`Qwen35.swift:253–294` constructs `Qwen3NextRMSNormGated` with the value-head dimension.
The projected `z` is reshaped per value head. All three ordinary/CBv2/captured GDN
paths invoke `norm(out, gate: z)` before the output projection (lines 823, 875 and
1097). `Qwen3Next.swift:31–36` performs the existing MLX RMSNorm, converts the gate
and normalized result to F32, applies SiLU and multiplication, then casts to the
incoming hidden dtype. Full-attention paths retain `sigmoidMultiply` at
`Qwen35.swift:1190,1232`.

For this artifact, each of the 48 recurrent layers has 48 value heads of width 128.
The retained header-derived record has `in_proj_z.weight` packed shape `[6144,640]`,
`norm.weight` BF16 shape `[128]`, and `out_proj.weight` packed shape `[5120,768]`.
The norm/gate is per 128-wide value head, then flattened for the output projection.
All 48 sets were checked. The 16 full-attention layers instead have gated Q projection
shape `[12288,640]`, also checked. Headers describe dimensions/storage, not which
activation a runtime executes. Their original range-fetch limitations remain intact.

Operator compatibility is weaker than numerical parity. MLX's fused RMSNorm and
reference normalization/weight multiplication can round differently; matching SiLU
and cast ordering does not prove equal BF16 logits, recurrent state or generation.
No gate kernel, real model or test was executed in this audit.

## Minimal adaptation before qualification

1. Add a closed supported-gate policy to the Qwen decoder/admission boundary. Preserve
   the legacy absent-field SiLU behavior. Recognize the actual `swish` spelling;
   `silu` can be admitted as the explicitly documented equivalent. Reject unknown
   strings, wrong types and explicit null rather than silently treating them as a
   supported gate. Preserve the original config and declared spelling in source
   identities; do not remove the property to pass a validator.
2. Teach `QwenLayerStageMetadata.validate` the same narrow supported-value rule,
   backed by that decoder policy. Adding the key to the allowlist without checking
   its value would leave the original silent-ignore problem. Keep the existing GDN
   and full-attention operations unchanged. Cover missing/swish/silu acceptance,
   malformed/unsupported rejection, and preservation through stage construction.
   These are proposed changes only; the frozen candidate helper still rejects the
   current 27B configuration through the existing metadata gate.
3. Separately qualify exact-artifact loading, state and outputs for the target
   hardware and admitted request geometry. Include the stored BF16 `A_log` to F32
   recurrence policy and actual normalization/projection rounding. A same-source
   baseline then needs to support each new candidate split; symbolic gate review
   supplies no 27B throughput or numerical result. Existing 9B pins, 16+16 state
   contracts and source-memory ceilings cannot be reused as 27B admission.

## M5/NAX is a separate enforced policy

The saved catalog requires `apple_m5` and `mlx_nax`. Provider
`ModelRuntimeRequirements.swift:139–161` also unions those requirements for both
exact published 27B IDs, preventing a missing catalog from dropping the restriction.
The detector grants `apple_m5` only to `.m5` and `mlx_nax` only after a nonempty bound
metallib hash plus the NAX diagnostic. Tests explicitly cover M1–M4 ineligibility.
Provider and standalone model loading call `requireEligible` before loading;
downloading applies the same evaluator with catalog requirements.

The introduction commit is `db969c4836d2833f8365410233bb8f6f226397b0` (2026-08-28).
The inspected policy/commit provides no gate-specific reason or demonstrated
non-NAX kernel failure. The catalog's provisional activation-floor note references
M4 Max non-NAX cells, but includes no raw measurements here. Neither proves M3
capability or impossibility. The exact 27B source bytes exceed the current
experimental 6 GiB canonical-source ceiling independently of gate semantics.
Eligibility and execution admission need their own authorized qualification work;
this audit changes neither and proposes no bypass.

## Evidence limits

`source-metadata-receipt.json` records matching config identities, 160 checked
retained header shapes, source assertions and 17 before/after-pinned local inputs.
`primary-fetch-receipt.json` pins the official raw sources. `audit_inputs.py` is a
small reproducible CPU reader; it imports no MLX, Torch or Transformers module.
The exact export development commit, unavailable catalog Hub revision, cross-runtime
rounding/parity, original non-M5 rollout rationale, full 27B artifact contents and
M3 performance remain unverified. Prior frozen evidence is unchanged.
