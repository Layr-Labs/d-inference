# Finding: Short In-Window Checkpoints Shadow the SSD Tier on Hybrid Models

**Status:** observed and root-caused on the M5 bench box (2026-06-07),
gpt-oss-20b. **Not yet fixed.** Behavior is conservative/correct (no wrong
output is ever produced), but it leaves prefill-skip on the table for hybrid
models with a **small** sliding window. Tracked here with proposed fixes for
discussion.

Background reading: [ssd-kv-cache.md](ssd-kv-cache.md) (how the tiers work) and
[ssd-kv-cache-hybrid-models.md](ssd-kv-cache-hybrid-models.md) (why hybrid
models use the exact-checkpoint tier).

---

## 1. Summary

For a hybrid sliding-window model with a **small** window (gpt-oss-20b:
window = 128), `PrefixCacheManager.lookup` can return a **128-token** RAM
checkpoint when a much larger (e.g. **2048-token**) checkpoint for the same
prompt is sitting on SSD. The cache "hits" (and counts the hit), but the
restored prefix is far shorter than what was actually cached — so the model
re-prefills ~1900 tokens it didn't have to.

The defect is in lookup **ordering**, not storage: the long checkpoints are
correctly persisted and evicted to SSD; they are just never consulted.

## 2. Mechanism

`lookup(tokens:)` in `PrefixCacheManager.swift` proceeds:

1. **Compute crossed checkpoint boundaries.** For gpt-oss the boundary ladder
   is `[64, 128, 2048, 4096, 8192, 16384, 32768]` — the in-window boundaries
   (64, 128) plus the proven past-window ladder. A 2500-token prompt crosses
   `[64, 128, 2048]`.
2. **RAM tier, longest-first.** Try 2048 in RAM; if present, return it. If the
   2048 checkpoint was RAM-evicted, the loop falls through to **128**, then
   **64** — and returns the **first boundary still resident in RAM**.
3. **SSD tier** is consulted only if *none* of the crossed boundaries hit in
   RAM.

The interaction that makes this pathological: **checkpoint size scales with
length**, so eviction pressure is wildly asymmetric across boundaries. For
gpt-oss:

| Checkpoint length | Approx. on-disk / RAM size |
|---|---|
| 64 tokens | ~0.7 MB |
| 128 tokens | ~1.4 MB |
| 2048 tokens | ~12 MB |

The 64- and 128-token checkpoints are tiny, so **dozens fit in the RAM tier
and effectively never get LRU-evicted**, even under a tight `MAX_GB`. The
valuable 2048-token checkpoint is large, gets RAM-evicted under pressure, and
lands on SSD — but step 2 returns the still-resident 128-token checkpoint
*before* step 3 ever runs. **The SSD tier is shadowed.**

## 3. Evidence

M5 bench box, gpt-oss-20b, round-robin over 60 distinct prefixes,
`MAX_GB=0.1` / `DISK_GB=0.05` (deliberately tight to force eviction):

```text
prefix cache stats: lookups=239 hits=223 (ram=223 ssd=0) misses=16 hitRate=93.3%
                    stores=8 ssdFlushes=15 diskEvictions=11 ssdReadErrors=0 ...
```

Reading the counters:

- `ssdFlushes=15`, `diskEvictions=11` → the 2048-token checkpoints **are**
  promoted to SSD and disk-evicted (disk grew to 41 MB / 4 files, then
  bounded). The write path works.
- `ssd=0` inside `hits=(ram=223 ssd=0)` → **not one** lookup ever reached the
  SSD tier, despite 60 distinct prefixes round-robined through an 8-slot RAM
  tier. The short in-window checkpoints satisfied every lookup.

**Contrast (why only small windows bite):** Gemma-4 (window 1024) has
boundaries `[256, 512, 1024]`, and its *smallest* checkpoint (256 tokens) is
already large (tens of MB). Its short checkpoints DO get evicted, so its SSD
tier is exercised heavily — the Gemma 4-hour soak recorded **1,280 SSD
evictions** with healthy SSD hits. The shadowing only occurs when the window —
hence the smallest boundary — is small enough that its checkpoints are
effectively eviction-proof.

## 4. Impact

- **Correctness: none.** A 128-token restore is valid; the suffix is
  re-prefilled correctly. No data is lost or mis-served.
- **Performance:** a hybrid small-window model under-uses its own SSD cache.
  A prompt that could skip 2048 tokens of prefill skips only 128. The warm
  probe still showed 3.7× TTFT benefit on a fully-RAM-resident long prefix,
  but once the long checkpoint is RAM-evicted the benefit silently degrades to
  the short checkpoint's, with no signal.
- **Observability:** hit-*rate* looks great (93–99%) while the *value* per hit
  is low — the hit counter cannot distinguish a 2048-token hit from a
  128-token hit. Dashboards reading hit-rate alone will not see this.

## 5. Proposed fixes (not implemented — for discussion)

1. **Prefer the longest checkpoint across BOTH tiers, not RAM-first
   (recommended).** Find the longest crossed boundary that exists in *either*
   the RAM tier or the SSD index, and load that — paying an SSD read +
   decrypt on the hot path when the longest available checkpoint is only on
   disk. For a 20B model, restoring 2048 tokens almost certainly beats
   re-prefilling them even with the decrypt; a simple cost model
   (`bytes/SSD-read-throughput` vs `tokens/prefill-TPS`) could gate the edge
   cases. This makes hit *value* match hit *count* and requires no storage
   changes.
2. **Don't persist tiny checkpoints when a larger boundary is also crossed** —
   for a long prompt, keep only the longest in-window + past-window
   checkpoints, skipping 64/128. Removes the shadowing entries entirely, but
   sacrifices the short checkpoints' (small) value for genuinely short
   prompts that share the prefix.
3. **Size-aware RAM eviction** — stop letting many tiny entries crowd out one
   large valuable one. Benefit-per-byte scoring already governs the *disk*
   tier; the RAM tier is plain LRU today. Indirect: fixes the eviction
   asymmetry rather than the lookup ordering, so it helps but does not
   guarantee the long checkpoint is chosen.

Whatever fix lands should also add a **restored-tokens metric** (sum of
restored prefix lengths, or value-weighted hit counter) so this class of
regression is visible in telemetry rather than masked by hit-rate.

## 6. Test-rig implication

A pure round-robin SSD-reload stress test does **not** work for gpt-oss
because of this shadowing — the short checkpoints absorb every lookup, so the
SSD read path gets zero coverage. Exercising the gpt-oss SSD-reload path
requires either fixing the lookup (option 1) or an artificial config that
suppresses the short boundaries. Until then, the Gemma soak remains the
representative SSD-reload stress (its boundaries are all large).
