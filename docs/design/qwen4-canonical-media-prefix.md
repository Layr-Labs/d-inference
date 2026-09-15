# Qwen4 media-prefix identity for appended text

> Last updated: 2026-09-14 · commit `e548a179`

Status: **In progress** — 2026-09-15 — implemented draft with scoped native/cache checks; full release qualification remains separate. See the [performance/stability record](../reports/2026-09-15-qwen38-performance-stability.md).

The existing binding includes the complete prompt length and position tensor.
Appending ordinary text therefore changes the media cache namespace even when
all previously evaluated inputs are identical. This design permits reuse only
when the omitted position suffix has an exact, checked representation.

## Binding and proof obligation

Let `E` be the end of the final ordered media span, `L` the prompt length,
and `d` the request's decode delta. For every axis and `E <= i < L`, require
the supplied position to equal `i + d` exactly, without integer overflow or
native Int32 decode clamping/wrapping. Require three axes, int32/int64 positions,
positive nonoverlapping ordered media spans within the prompt and causal
attention. Other cases retain the full existing binding.

The new domain hashes the complete position prefix `[0, E)`, its dtype/axes,
`E`, `d`, all media spans/kinds/embeddings, all DeepStack levels and attention.
The existing SDK still folds the authenticated tenant scope once and checks
model/layout identity, exact token-prefix equality, native checkpoint geometry
and all QSA/GDN/PLE state before adoption.

For two requests with equal new bindings, every supplied position before `E`
is committed explicitly; every later common position is the same checked
function `i + d`. Thus their positions agree across any common token prefix.
An appended token or changed text is still handled by the token chain. Changed
media or positions before `E` alter the binding; a corrupt tail falls back to
the full old-domain binding and cannot alias a normalized checkpoint. Domain
separation prevents new normalized keys from reinterpreting old full keys.

This argument does not by itself prove numerical cache continuation or lifecycle
correctness. Those remain native execution gates, including chunk boundaries,
QSA/GDN/PLE state, cancellation, eviction and encrypted SSD restore.

## Scope and code

- `Qwen4CanonicalMediaPositions.prefixLength` is the pure integer proof.
- `EngineV2HybridPrefixIdentityBuilder.make` opts into the new domain only after
  that proof succeeds; its default remains full-request binding.
- `EngineV2VisionPrefill.PreparedSubmission.hybridPrefixIdentity` carries the
  explicit opt-in without modifying media or positions.
- `MultiModelBatchSchedulerEngine` opts in only inside the existing exact-owned
  Qwen4/media/cache/store gate. Other models retain the old behavior.

No weights, quantization, prompt/tokenizer behavior, attention computation,
tool parsing, learned-table policy, MTP eligibility or cache capacity changes.
Media remains target-only. The change is private until the human approves
public promotion after qualification.

## Required regression cells

Prove exact repeat and text append reuse against uncached execution, including
image, video and mixed history. Retain changed content/order/kind/DeepStack,
prefix/tail positions, dtype/delta/attention, tenant/model/template/epoch and
corrupt-manifest negatives. Test unknown/noncanonical fallback, overflow,
empty/no-tail boundaries, first-use and warm behavior, cancellation/readmission,
SSD and resident ownership, both APIs/reasoning modes/tools, and other families.
Report semantic output quality separately from cache equivalence and throughput.

See [prefix-cache architecture](../architecture/prefix-cache.md) and
[native support](../reference/qwen4-next-support.md).
