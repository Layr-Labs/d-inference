# 078 — Qwen suffix-frontier state river handoff

Date: 2026-08-24  
Status: **implemented as an ordered patch; default off; M3 performance and
semantic quality pending**

## Contract

The E49 state river now runs the final configurable N prompt rows through every
skipped layer's complete attention/GDN, residual, and MLP path. The default is
64:

```bash
export DARKBLOOM_QWEN35_PREFILL_ARTIFACT_ONLY=1
export DARKBLOOM_QWEN35_PREFILL_FRONTIER_TOKENS=64
```

Rows before that suffix retain the artifact-only path. The engine computes the
suffix overlap for each prompt chunk, so a suffix beginning in an intermediate
chunk continues through later chunks without replay. Packed rows are grouped
only when their overlap counts match.

Attention layers commit history K/V once and then update-and-attend the suffix
once. GDN layers fold history into a private prefix state, process the suffix
chronologically, and stage only the post-suffix generation. Cache offsets
therefore advance by the chunk length, never by history plus a duplicated
frontier.

Decode, MTP phases, vision embedding prefill, unarmed configurations, and
ordinary intermediate chunks remain on their prior paths.

## Regression coverage

The patch adds or extends coverage for:

- strict default/override parsing of the 64-token frontier;
- scheduler signaling when the suffix crosses a chunk boundary;
- attention K/V and GDN state equivalence for a three-row full suffix;
- B1/B2/B4 three-chunk transactions where the five-row suffix crosses the
  second chunk;
- exact cache offsets, recurrent commit/rollback, cancelled-row release, and
  survivor K/V isolation;
- unchanged decode/MTP phase behavior and default-off requirements.

## Ordered patch

Apply `078-cbv2-suffix-frontier-state-river.patch` after patch 076's final
nested commit `420ece51556a45c3f0312f6e6dac4be45a318c1a`.

- patch SHA-256:
  `6004250175d499075bb36c7e9438d11e5243bf341be2b2d6ff4cb646e5b397bb`;
- nested commits:
  `0a9965992199e8381d810767b4118b29f0285aae`,
  `e5ba752`;
- final tree: `94d315172685c559c51b5622a887893c824c1723`, verified by
  clean patch replay.

The Linux host parses every changed Swift file and type-checks the standalone
policy files. Full package compilation cannot reach the changed targets here:
the CPU-only MLX dependency build fails in its pre-existing `MLXFast` target,
while the default Linux build requires unavailable CUDA headers. Run the
focused Swift tests and M3 speed/quality gates on the parent Mac.
