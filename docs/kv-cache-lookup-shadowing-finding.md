# Finding: short in-window checkpoints shadow the SSD tier on hybrid models

**Status:** observed + root-caused on the M5 bench box (2026-06-07), gpt-oss-20b.
Not yet fixed. Conservative/correct behavior, but leaves prefill-skip on the table
for short-sliding-window hybrid models.

## Summary

For a hybrid sliding-window model with a **small** window (gpt-oss-20b: window
= 128), `PrefixCacheManager.lookup` can return a **128-token** RAM checkpoint
when a much larger (e.g. **2048-token**) checkpoint for the same prompt is
sitting on SSD. The cache "hits" (and counts the hit), but the restored prefix
is far shorter than what was actually cached — so the model re-prefills ~1900
tokens it didn't have to.

## Mechanism

`lookup(tokens:)` (PrefixCacheManager.swift):

1. Computes the crossed checkpoint boundaries. For gpt-oss the boundaries are
   `[64, 128, 2048, 4096, 8192, 16384, 32768]` (in-window 64/128 + the proven
   past-window ladder). A 2500-token prompt crosses `[64, 128, 2048]`.
2. **RAM tier, longest-first:** tries 2048 in RAM; if present, returns it.
   If the 2048 checkpoint was RAM-evicted, the loop falls through to **128**,
   then **64** — and returns the first one still in RAM.
3. **SSD tier** is only consulted if *none* of the boundaries hit in RAM.

The catch: checkpoint size scales with length. For gpt-oss:

| checkpoint length | approx on-disk / RAM size |
|---|---|
| 64 tokens  | ~0.7 MB |
| 128 tokens | ~1.4 MB |
| 2048 tokens | ~12 MB |

The 64- and 128-token checkpoints are tiny, so **dozens fit in the RAM tier and
effectively never get LRU-evicted**, even under a tight `MAX_GB`. The valuable
2048-token checkpoint is large, gets RAM-evicted under pressure, lands on SSD —
but step 2 returns the still-resident 128-token checkpoint *before* step 3 ever
runs. **The SSD tier is shadowed.**

## Evidence (M5, gpt-oss-20b, round-robin over 60 prefixes, MAX_GB=0.1/DISK_GB=0.05)

```
prefix cache stats: lookups=239 hits=223 (ram=223 ssd=0) misses=16 hitRate=93.3%
                    stores=8 ssdFlushes=15 diskEvictions=11 ssdReadErrors=0 ...
```

- `ssdFlushes=15`, `diskEvictions=11` → the 2048 checkpoints ARE promoted to SSD
  and evicted (disk grew to 41 MB / 4 files then bounded).
- `ssd=0` in `hits=(ram=223 ssd=0)` → **not one** lookup ever reached the SSD
  tier, despite 60 distinct prefixes round-robined through an 8-slot RAM tier.
  The short checkpoints satisfied every lookup.

By contrast, Gemma-4 (window 1024) has boundaries `[256, 512, 1024]` and its
*smallest* checkpoint (256) is already large (~tens of MB), so its short
checkpoints DO evict and its SSD tier is exercised heavily (the Gemma 4h soak
saw 1,280 SSD evictions). The shadowing only bites when the window — hence the
smallest boundary — is small.

## Impact

- **Correctness:** none. A 128-token restore is valid; the suffix is re-prefilled
  correctly. No data is lost or mis-served.
- **Performance:** a hybrid small-window model under-uses its own SSD cache.
  A prompt that could skip 2048 tokens of prefill skips only 128. For gpt-oss the
  warm benefit still showed 3.7× on a fully-RAM-resident prefix (probe), but once
  the long checkpoint is RAM-evicted the benefit silently drops to the short one.
- **Observability:** hit-rate looks great (~93–99%) while the *value* per hit is
  low — the counter can't distinguish a 2048-token hit from a 128-token hit.

## Possible fixes (not implemented — for discussion)

1. **Prefer the longest checkpoint across BOTH tiers, not RAM-first.** Find the
   longest crossed boundary that exists in *either* RAM or the index, and load
   that — reading SSD when the longest available checkpoint is only on disk.
   Cost: an SSD read (decrypt) on the hot path when the long checkpoint was
   evicted; weigh against the prefill saved (for a 20B model, restoring 2048
   tokens almost certainly beats re-prefilling them even with a decrypt).
2. **Don't cache/persist tiny checkpoints when a larger boundary is also crossed**
   — i.e. for a long prompt, keep only the longest in-window + past-window
   checkpoints, skipping 64/128. Removes the shadowing entries entirely.
3. **Size-aware RAM eviction** that doesn't let many tiny entries crowd out the
   value of a single large one (benefit-per-byte already governs *disk*; the RAM
   tier is plain LRU).

Option 1 is the most direct: it makes the hit *value* match the hit *count*.

## Test-rig implication

A pure round-robin SSD-reload stress test does **not** work for gpt-oss because
of this shadowing — the short checkpoints absorb every lookup. Exercising the
gpt-oss SSD-reload path would require either fixing the lookup (option 1) or an
artificial config that suppresses the short boundaries. The Gemma soak remains
the representative SSD-reload stress (its boundaries are all large).
