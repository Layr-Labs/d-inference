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
2. ✅ `servabilityPerModelFloorMinVersion` "0.8.11" (stale placeholder) →
   **"0.8.16"**, and the coupling is COMPLETED in this tree:
   `ProviderCore.version` and `LatestProviderVersion` are both 0.8.16 (the
   `TestLatestProviderVersionMatchesProviderCore` pairing test enforces it). The
   release that ships this must be tagged exactly v0.8.16 (plain numeric —
   `CompareVersions` parses non-numeric segments as 0, so no `-swift.N` suffix).
3. Keep the gpt-oss floor at 3.5 GiB — validated on the current engine (2.63
   measured B=8, same convention; July's 3.20 compiled path no longer exists).
4. Full test suites: provider Swift (`swift test`) + coordinator Go (`go test ./...`).
   Tests are live-isolated per repo convention; nothing points at prod.

## Phase 2 — qwen3.6 B=8 measurement → qwen floor entry (or tier correction)

**Status 2026-08-30 night: measurement COMPLETE; both outcomes apply.**

1. ✅ Root-caused the "SIGTRAP": an Index-out-of-range in the bench's **v2-paged**
   cache wiring only (dense per-storage `pagedCaches[index]` fed the hybrid trunk's
   sparse MODEL layer index from `newCacheV2`), masked as a whole-family failure by
   the buffered perf table. Stock contiguous runs fine — and a code trace confirmed
   the bench's stock profile IS production's decode/prefill route (optimized
   lanes are bench-only or env-gated OFF). Since #777 (v0.8.14 train) embedded
   MTP heads auto-activate in production, so live qwen3.6 decode additionally
   runs MTP k=2 — the B=1-measured +0.4 GiB allowance now applies to the live
   route (floors stay deferred for the vision reason below regardless).
   Fix committed on `fix/qwen35-stock-bench-trap` (mlx-swift-lm worktree; separate
   PR in that repo, merged as mlx-swift-lm#129). ✅ **The production factory carried
   the identical subscript and is fixed on this branch**: the paged-cache wiring now
   maps each cache's model-layer index to its storage slot
   (`EngineV2Factory+Production.swift:1018-1044`, `preconditionFailure` on an
   impossible miss). Unreachable today only because `supportsPagedKV` vetoes paged
   for hybrid trunks upstream; the mapping makes it safe the day that flips.
2. ✅ Measured on the served artifact (hub 73a03825), v2 contiguous, current engine:
   B=8 = 3.28 GiB @ 500 tok; raw 4.06 @ 4k, 4.87 @ 8k; decomposed non-KV envelope
   **~3.3 GiB, saturated** (hybrid trunk — no composed-attention blow-up). MTP delta
   ≈ +0.4 GiB (B=1-measured; a B=8 MTP figure needs the campaign B=N harness
   extension — do with the harness PR).
3. **Resolved as follows** (superseded by the PR review — see Phase 3 status):
   (a) the 4.0 GiB floor entry is a REJECTED-FOR-NOW candidate: qwen3.6 is
   vision-capable and the tower transient rides this reserve, so the
   text-decode measurement alone must not lower it — the entry is DEFERRED
   behind a vision-inclusive measurement (shipped tables carry gpt-oss only).
   (b) the catalog correction `min_ram_gb` 32 → 36 is REQUIRED regardless:
   at the shipped 5.5 default the tier does not fit (30.3 > 28.8 cap), and
   even at a future 4.0 floor a 32 GiB box retains <4 GiB for macOS.

## Phase 3 — measured-weights estimate + default retune → follow-up PR(s)

**Status 2026-08-31 (final, post-review): 3a shipped NARROWED (gpt-oss-only
residency); 3b fully DEFERRED (both qwen floors + the default retune, all
behind vision-inclusive measurement); 3c resolved by discovery.**

Tier truth at the shipped tables: gpt-oss@24 fits (measured floor+weights);
qwen3.5@36 and gemma-qat4@36 fit at the 5.5 default; **qwen3.6's 32 GB tier
does NOT fit at 5.5 (23.8 + 5.5 + 1.0 = 30.3 > 28.8 cap) — the re-tier to
36 remains REQUIRED**; and **gemma-8bit's 36 GB tier remains blocked at
padded weights** until the provider-path (VLM) residency measurement lands.

- 3a ✅ (narrowed TWICE per PR review, final shape) measured post-load
  residency lives ONLY in the coordinator's `servabilityMeasuredResidentGiB`
  (gpt-oss only; canonical values from the report) feeding ONLY
  `coldTokenBudgetEstimate` — the POST-load token-budget arithmetic. Every
  ADMIT-time gate (provider load gate, pending-load reservation, startup
  preload, doctor, `reportedFreeForLoadAdmits`) deliberately keeps the
  padded disk×1.2 figure: the LOAD TRANSIENT (shard staging) exceeds steady
  residency, which is exactly what the padding was sized for. Consequences:
  the gemma-8bit 36 GB tier unblock now requires a measured LOAD-PEAK (not
  just steady residency) through the provider's VLM path — recorded as the
  follow-up gate; and there is no provider-side weights table by design.
- 3b ◐ (narrowed per PR review) the qwen3.5/3.6 floor entries are DEFERRED
  along with the default retune, all behind the same gate: **vision-inclusive
  measurement**. The qwens are vision-capable and the tower transient rides
  the reserve — text-decode evidence (~3.3 GiB envelope, measured both
  models) must not lower it. The measured data stands in the report as the
  text-decode baseline; the 32 GB qwen3.6 tier verdict is unchanged and
  still REQUIRED: it does not fit at the 5.5 default (30.3 > 28.8 cap) —
  re-tier to 36. qwen3.5@36 and qat-4bit@36 do fit at 5.5.
- 3c ✅ superseded by master: `qwen3-vl-30b-a3b-instruct` is SERVED in
  production since the v0.8.14 train — #752 added the `qwen3_vl_moe` family:
  the supported-family predicate admits it
  (`provider-swift/Sources/ProviderCore/Inference/EngineV2SupportedModels.swift:48`,
  `if raw == "qwen3_vl_moe" { return true }`), VLM text extraction returns
  the Qwen3-VL wrapper itself as the serving model
  (`provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift:101`),
  and the production construction switch has a direct arm for it
  (`EngineV2Factory+Production.swift:697`, `case let qwen as MLXVLM.Qwen3VL`
  in `prepareProductionBackend`; the capability/layer-kind switches at :329
  and :350 likewise). Vision is kept off M5 by #781. What remains is the MEASUREMENT gap: the bench loads through the
  LLM factory and cannot construct `qwen3_vl_moe`, so its activation floor
  stays at the 5.5 default (it fits its 32 GB tier there: 20.5 + 5.5 + 1.0 =
  27.0 ≤ 28.8) until the bench gains a VLM-factory load path — the same
  vision-inclusive measurement gate as the other deferred entries.

### Original phase text (for context)

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
- Vision-inclusive activation peaks for VL models. The vision-tower transient rides
  the activation reserve — `VisionMemoryGate` reserves decoded-media buffers and KV,
  not the tower's activations — which is exactly why vision-capable models keep the
  default floor until a vision-inclusive B=8 measurement exists. A text-only figure
  must never lower their floor.

## Sequencing and gates

- Phase 1 is independent and ships first (this branch → PR).
- Phase 2's harness fix runs in parallel (submodule worktree); its floor entry lands
  as a follow-up commit/PR once the number exists.
- Phase 3 lands per-lever as measurements complete. 3a is ready ONLY for gpt-oss
  (11.25 GiB measured, text-only artifact — shipped as 11.5 in Phase 1). gemma-qat4
  stays DEFERRED: its checkpoint declares `vision_config`, so the provider loads it
  through the VLM factory (`ModelContainerLoading.swift`), and the text-only 13.48 GiB
  figure undercounts the tower — the same vision gate as above; measure the
  provider's VLM load path before it joins the table.
- Every phase: no pushes without explicit go-ahead; live-isolated tests included.
