# Activation reserve overhaul — plan

Fixes the over-reservation class that leaves machines online but unable to load (or
serve) models they should fit: issue #653, the unserveable 24 GB gpt-oss tier, the
32 GB qwen3.6 tier, and the padded-weights overshoot that breaks the 36 GB
gemma-8bit tier.

Grounded in the 2026-08-30 measurement sweep
(`docs/reports/2026-08-30-activation-floor-measurements.md`): the 5.5 GiB flat
activation reserve's basis measurement (gemma qat-4bit B=8 = 5.05 GiB, July 2026)
measures **2.28 GiB** on the current engine (saturated long-prompt envelope ~3.6);
gpt-oss measures 2.63 (envelope ~2.7); the padded-weights estimate overshoots real
MLX residency by ~6 GiB on the 26B 8bit artifact (est. ~31.3 vs 24.97 measured).

Branch: `feat/activation-reserve-overhaul` (worktree `.worktrees/activation-reserve-overhaul`).
Base: PR #683 by Jeremy Joplin (`jkjoplin:fix/per-model-activation-floor`),
cherry-picked with original authorship preserved (088094491); all subsequent commits
that modify his machinery carry `Co-authored-by: Jeremy Joplin <jeremykjoplin@gmail.com>`.
PR #654 is superseded (it removes the raise-only env clamp and leaves
KVHeadroomProbe/GlobalKVCacheBudget on the flat reserve — the admit-then-unload trap).

## Phase 1 — per-model activation floors (#683 + corrections) → one PR, ships first

Unblocks the 24 GB gpt-oss tier (needs 20.0 → 18.0 GB).

1. ✅ Cherry-pick #683 onto master (clean; 24 files, +599/−127).
2. Bump `servabilityPerModelFloorMinVersion` "0.8.11" (stale placeholder; train is at
   0.8.15) → **"0.8.16"**, with a comment making the release coupling explicit.
   **RELEASE COUPLING**: the release that ships this must be numbered exactly that
   (plain numeric — `CompareVersions` parses non-numeric segments as 0, so no
   `-swift.N` suffix), or the constant must be updated in the release commit.
   Master's `ProviderCore.version` currently reads "0.8.13" while the fleet runs
   0.8.15 (releases cut on branches) — verify the actual next train number at cut.
3. Keep the gpt-oss floor at 3.5 GiB — validated on the current engine (2.63
   measured B=8, same convention; July's 3.20 compiled path no longer exists).
4. Full test suites: provider Swift (`swift test`) + coordinator Go (`go test ./...`).
   Tests are live-isolated per repo convention; nothing points at prod.

## Phase 2 — qwen3.6 B=8 measurement → qwen floor entry (or tier correction)

Unblocks (or honestly re-tiers) the 32 GB qwen3.6 tier: needs floor ≤ 4.0
(23.8 padded + floor + 1.0 ≤ 28.8 cap), and even then leaves <4 GiB for macOS on a
32 GiB box — the measurement decides between a floor entry and `min_ram_gb: 36`.

1. Fix the bench-harness SIGTRAP: stock `--mode perf` traps at the first v2 warmup
   cell for the `qwen3_5_moe` family (`libs/mlx-swift-lm`, own worktree — submodule
   changes are a separate PR in that repo). Campaign mode (same `makeV2Engine`, same
   hooks, near-identical scheduler config) works at B=1, so the delta is narrow:
   task-group submission or synthetic-prompt shape.
2. Measure qwen3.6-35b B=8 on the served artifact (hub rev 73a03825, verified
   identical to the catalog's `hub_revision`; "mxfp8" in the id names the inline-MTP
   head quant): 500-token AND ≥4k-token cells (the sweep showed short-prompt cells
   under-measure the saturated envelope), MTP k=2 active (production posture).
3. Outcome A (saturated envelope ≤ ~3.5–4.0): add
   `qwen3.6-35b-a3b-vl-mtp-mxfp8` to `measuredActivationFloorsBytes` +
   `servabilityModelActivationFloorsGB` in one commit (the #683 contract).
   Outcome B (> 4.0): propose the catalog `min_ram_gb` 32 → 36 correction instead
   (runtime catalog data — an ops change, documented, not code).

## Phase 3 — measured-weights estimate + default retune → follow-up PR(s)

3a. **Measured resident weights per artifact** (new lever from the sweep): the
    disk×1.2 / catalog×1.1176 padding overshoots real residency (~6 GiB phantom
    need on gemma-8bit → its 36 GB tier is arithmetically dead today: 31.3 + floor
    + 1 > 32.4 cap; measured 24.97 + 3.6 + 1 = 29.6 fits). Same twin-table shape as
    the floors: measured residency keyed by catalog id on the provider, mirrored in
    servability, raise-only-style conservative fallback to the padded estimate for
    unmeasured artifacts, both sides in one commit.
    **Measurement criterion**: residency must be taken through a load path that
    materializes everything serving needs — for VL models that includes the vision
    tower (the bench's text-only active under-counts it; VisionMemoryGate gates
    vision separately but resident weights must be honest).
3b. **Default retune 5.5 → ~4.5** (worst current-engine saturated envelope + slack),
    once every catalog model is measured under the ≥4k B=8 convention. Provider +
    coordinator in one commit — the sanctioned "move the FLAT floor" shape. Shrinks
    the per-model table to models genuinely below the retuned default.
3c. Prereq for 3b: bench registry support for `qwen3_vl_moe` (Qwen3-VL-30B cannot
    load in the bench at all today), and a measured qwen3.5-35b (local artifact
    rev 8964653 predates the router8 campaign contract; needs catalog rev 59d61f3c).

## Deferred (explicitly out of scope)

- Moving floors/residency from hardcoded twin tables into a measured **catalog
  field** populated by the onboarding bench — the durable fix for constants going
  silently stale (the 5.5 default did exactly that when the engine improved). Do it
  after the above ships and the numbers have soaked.
- Vision-inclusive activation peaks for VL models (contained by VisionMemoryGate).

## Sequencing and gates

- Phase 1 is independent and ships first (this branch → PR).
- Phase 2's harness fix runs in parallel (submodule worktree); its floor entry lands
  as a follow-up commit/PR once the number exists.
- Phase 3 lands per-lever as measurements complete; 3a can start now for the
  non-VL artifacts already measured (gpt-oss 11.25, gemma-qat4 13.48 GiB) if their
  vision-inclusiveness criterion is confirmed n/a (both text-only models).
- Every phase: no pushes without explicit go-ahead; live-isolated tests included.
