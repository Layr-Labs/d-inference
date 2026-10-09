# Host memory gate, version 3: counting file cache the kernel will give up

> 2026-10-09, branch `work/resource-gate-v3`. The measurements, the rule and
> the rejected alternatives were written before the implementation; "Proof on
> hardware" and the cost figures were added after it.
> "Mac A" is the M3 Ultra (256 GB, macOS 27.2), "Mac B" the M5 Max (128 GB,
> macOS 27.0). Raw samples are outside the repository in the task's evidence
> folder `gate-v3-20261009`.

## The problem

The resident load gate, the request gate and the diagnostics gate admit on
actual free pages only (`registered_dense_selected_stage_load_resources_v2`):
at least 6 GiB free, and during a load the remaining tensors plus two host
copies plus 4 GiB. macOS keeps almost nothing free once files have been read.
After a model download or a hash pass a Mac holds a few hundred MiB free and
tens of GiB of file cache, so the product refuses its own first start. Both
Macs were in that state for most of a night and refused 27B loads, 8,192-token
requests and the single-Mac reference.

## What was measured

Read-only sampling of `host_statistics64(HOST_VM_INFO64)`, the pressure level
and swap usage every 0.2 s around real stage loads. The cache was filled the
ordinary way, by reading existing model files until free pages ran out. A
measurement-only build skipped the free-page comparisons; it was never
committed (the patch is kept with the evidence).

Weights show up as anonymous pages of the loading process, not as wired pages.

### One load with the cache full

| Mac | Stage | Free before | File-backed before | Load | File-backed at peak | Free at peak | Lowest free | Pressure | Compressed | Swapped out |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|---:|
| A | 27B rank 1, cut 16 (10.24 GiB) | 0.28 GiB | 143.8 GiB | 13.1 s | −9.7 GiB | −0.2 GiB | 0.10 GiB | normal | 0.05 GiB | 0 |
| A | same, second run | 1.77 | 143.1 | 12.8 s | −8.9 | −1.7 | 0.10 | normal | 0 | 0 |
| A | 9B rank 1, cut 4 (3.71 GiB) | 0.22 | 144.7 | 5.0 s | −4.1 | −0.1 | 0.10 | normal | 0 | 0 |
| A | same, second run | 1.25 | 143.7 | 5.0 s | −3.2 | −1.1 | 0.10 | normal | 0 | 0 |
| B | 27B rank 1, cut 16 | 1.34 | 79.9 | 8.4 s | −9.9 | −1.0 | 0.31 | normal | 0 | 0 |
| B | same, second run | 1.28 | 79.9 | 8.4 s | −9.2 | −1.0 | 0.31 | normal | 0 | 0 |
| B | 9B rank 1, cut 4 | 1.20 | 79.9 | 3.3 s | −3.0 | −0.9 | 0.32 | normal | 0 | 0 |
| B | same, second run | 0.35 | 80.9 | 3.3 s | −3.9 | −0.0 | 0.32 | normal | 0 | 0 |

The v2 gate refused all four stages in that state ("requires at least 6 GiB
actual free memory"). With free memory on Mac A (86–89 GiB free) the same
loads took 13.1 s and 5.0 s: no measurable cost there. Mac B had no
free-memory state in that session; the same-session comparison for Mac B is
in "Proof on hardware" below (8.4 s either way).

The kernel supplied the pages from inactive file-backed memory as fast as the
loader asked (about 5 GiB/s), kept its own small free pool (0.10 GiB on Mac A,
0.31 GiB on Mac B), compressed nothing and swapped nothing. After release the
weights' pages became free pages; the cache did not come back by itself.

### How far the cache can be drawn

Loaded stages were held resident one after another: 27B rank-1 stages at
cut 4 (12.6 GiB each), then 9B rank-1 stages (3.7 GiB each), down to the
kernel's file-cache minimum and two 9B stages past it. Mac B:

| Held | File-backed | Kernel file-cache minimum | Above minimum | Anonymous | Inactive | Compressor | Swap | Pressure |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| nothing (cache full) | 80.9 GiB | 44.5 GiB | +36.4 | 39.0 | 87.8 | 1.51 | 1.18 | normal |
| 1 × 27B | 67.8 | 44.5 | +23.3 | 52.0 | 74.6 | 1.51 | 1.18 | normal |
| 2 × 27B | 55.0 | 44.5 | +10.5 | 65.3 | 61.9 | 1.51 | 1.18 | normal |
| + 2 × 9B | 46.0 | 44.6 | +1.4 | 74.1 | 60.0 | 1.51 | 1.18 | normal |
| + 3 × 9B | 41.7 | 44.5 | −2.8 | 78.4 | 60.1 | 1.51 | 1.18 | normal |
| + 4 × 9B (43.5 GiB held) | 37.5 | 44.5 | −7.0 | 82.6 | 60.0 | 1.51 | 1.18 | normal |

Over the whole run: 0.000 GiB compressed, 0 swapped out, pressure normal in
all 383 samples, lowest free 0.26 GiB. All six processes released and exited 0.

Mac A, the same procedure (four 27B stages, then four 9B stages):

| Held | File-backed | Kernel file-cache minimum | Above minimum | Anonymous | Inactive | Compressor | Pressure |
|---|---:|---:|---:|---:|---:|---:|---|
| nothing (cache full) | 156.2 GiB | 91.4 GiB | +64.9 | 90.3 | 203.9 | 1.05 | normal |
| 2 × 27B | 129.8 | 91.4 | +38.4 | 116.0 | 178.2 | 1.05 | normal |
| 4 × 27B | 102.9 | 91.2 | +11.7 | 142.9 | 151.4 | 1.05 | normal |
| + 2 × 9B | 94.3 | 91.2 | +3.1 | 151.9 | 142.8 | 1.05 | normal |
| + 3 × 9B | 90.8 | 91.4 | −0.6 | 155.4 | 139.3 | 1.05 | normal |
| + 4 × 9B (65.3 GiB held) | 85.7 | 91.0 | −5.4 | 160.1 | 134.1 | 1.05 | normal |

0.000 GiB compressed, nothing swapped (Mac A has no swap in use), pressure
normal in all 463 samples, lowest free 0.10 GiB, all eight processes released
and exited 0. While the stages were still held, 49 GiB of file-backed memory
turned into free pages within ten seconds with no matching consumer, which is
what deleting cached files looks like; it was not caused by these loads.

The "kernel file-cache minimum" is `vm.vm_page_filecache_min`. In XNU
(`vps_calculate_filecache_min`) it is the non-compressed pageable memory
(active + inactive + free + speculative) × 10 / 27 on macOS, and
`vps_choose_victim_page` turns to anonymous pages, which means the compressor,
when file-backed memory is below it or when too little of the file cache is
inactive. The sysctl is recomputed only when the pageout scan runs: it read
34.0 GiB before the first load and 44.5 GiB from then on, and the formula
applied to the same snapshot gives 44.5.

So on both Macs the file cache above the kernel's own minimum was available in
full (36 GiB on Mac B, 65 GiB on Mac A), and another 5 to 7 GiB below it went
without compression too. From the point
where inactive memory reached half of pageable memory the kernel held it there
by deactivating pages, which puts idle anonymous pages next in line; that is
the regime this rule stays out of.

## The rule

Admissible memory for a decision that needs `required` bytes:

```
pageable   = active + inactive + free (speculative included)
reserve    = max(pageable × 10 / 27, kernel-reported minimum if readable)
counted    = 0                                     unless pressure is normal
           = min(32 GiB, ¾ × max(0, file-backed − reserve))
admissible = actual free + counted
admit      ⇔ observation valid
             ∧ actual free ≥ 16 MiB
             ∧ admissible ≥ max(6 GiB, required)
```

- **Counted:** file-backed pages (`external_page_count`) above the reserve.
  They are what the kernel gives up before it touches anonymous memory.
- **Reserve:** the kernel's own file-cache minimum, computed from the same
  snapshot with the kernel's formula, and the kernel-reported value when that
  is larger. A load turns file cache into anonymous memory, which leaves
  pageable memory and therefore the reserve unchanged, so "above the reserve
  now" is "above the reserve after the load".
- **Three quarters:** one quarter of the cache above the reserve is left
  uncounted for pages that cannot be dropped at once (dirty, busy, mapped and
  in use) and for other processes allocating between the sample and the use.
  The measurement showed all of it available on both Macs; the fraction is
  margin, not a measured loss.
- **32 GiB cap:** three quarters of the draw from file cache shown with real
  loads on the smaller Mac (43.5 GiB; 70.9 GiB on the larger). No single
  decision relies on more than has been demonstrated with margin.
- **Pressure:** file cache counts only while
  `kern.memorystatus_vm_pressure_level` is normal. At warning the rule is the
  old one: free pages only.
- **16 MiB truly free:** about the kernel's reserved pool on both Macs (914
  and 924 pages). The kernel ran loads at 0.10 GiB free, so any larger floor
  would refuse the state this change exists to admit. Below 16 MiB the kernel
  is not turning cache into free pages fast enough, and nothing is admitted.
- **6 GiB floor:** unchanged in size, now on admissible memory.
- **Unchanged:** the swap-under-pressure refusal, critical pressure, stale or
  inconsistent observations, every allocator-limit comparison, the per-tensor
  and 250 ms re-checks, the requirement formulas at the three call sites.

Every re-check is a fresh sample, so a load that was admitted on cache stops
at the next tensor if pressure leaves normal or the cache is gone.

### Rejected

- **Counting inactive pages** (what the ordinary provider does by default).
  On Mac A 102 GiB was anonymous and most of it inactive; taking those pages
  means compressing them.
- **A flat fraction of file-backed pages.** It ignores the kernel's minimum:
  half of an 80 GiB cache on Mac B is 40 GiB, which is past the point where
  the kernel starts looking at anonymous memory (36 GiB above the minimum).
- **Purgeable pages.** 0.2–1.8 GiB on these Macs, and the kernel purged
  0.05 GiB while giving up 43.5 GiB of cache: it was not the source.
- **Speculative pages as a separate term.** They are file-backed and already
  inside the counted quantity; in the cache-heavy state there were none.
- **Using the sysctl alone for the reserve.** It was 10 GiB stale at the
  moment a decision would have been taken.
- **A larger truly-free floor.** See above.
- **A guard on compressor or swap growth since the first sample.** It needs
  state carried between decisions and would refuse on another process's
  activity. Nothing in the measurements calls for it; it is the first thing to
  add if a Mac is ever seen compressing during an admitted load.
- **Waiting and re-sampling, or reclaiming explicitly.** The cache-heavy
  state does not resolve by waiting, and a product that allocates memory to
  evict cache is the workaround this replaces.

## Where it lives

`QwenDenseStageLoadPolicy` decides and names the numbers in a refusal.
`QwenDenseStageLoadResources` samples the counters, asks the policy and keeps
a record of this process's decisions (count, first, tightest, whether any
needed file cache). The load gate, the request gate and the diagnostics gate
each change one line: the comparison with free bytes becomes a question to
the policy. The stage check and the reference print the record.

## Proof on hardware

The rule as implemented, no override, on both Macs. "Cache full" means free
pages were exhausted by reading model files (0.15–2 GiB free; 153–157 GiB
file-backed on Mac A, 81–82 GiB on Mac B). The receipts are the gate's own
record; the counters were sampled every 0.2 s from outside the process.

### Stage loads (rank 1, the large stage)

| Mac | Stage | State | Load | Admitted on | Pressure | Compressed | Swapped out | After release |
|---|---|---|---:|---|---|---:|---:|---|
| A | 27B, cut 16 (10.24 GiB) | cache full | 12.98 s, 12.75 s | free 0.1–2.1 + cache 32.0 (cap) for 14.8 GiB | normal | 0 | 0 | 5,976 B active, 0 cached |
| A | same | 58 GiB free | 12.70 s | free pages alone | normal | 0 | 0 | same |
| A | 9B, cut 4 (3.71 GiB) | cache full | 4.91 s, 4.89 s | free 0.13 + cache 32.0 for 8.7 GiB | normal | 0 | 0 | 3,496 B active, 0 cached |
| A | same | 58 GiB free | 4.88 s | free pages alone | normal | 0 | 0 | same |
| B | 27B, cut 16 | cache full | 8.43 s, 8.39 s | free 0.1–1.0 + cache 27.2–28.0 for 15.4 GiB | normal | 0 | 0 | 5,976 B active, 0 cached |
| B | same | 27 GiB free | 8.44 s | free pages alone | normal | 0 | 0 | same |
| B | 9B, cut 4 | cache full | 3.30 s, 3.31 s | free 0.1–1.0 + cache 27.2–27.9 for 8.7 GiB | normal | 0 | 0 | 3,496 B active, 0 cached |
| B | same | 27 GiB free | 3.32 s | free pages alone | normal | 0 | 0 | same |

Version 2 refused every cache-full row. Load time is the same with the cache
full as with free memory. After release the stage's memory was free pages
again (about 11 GiB and 4.5 GiB more free than before the load).

### Single-Mac reference (8,192-token prompt, chunk 512, both stages in one process)

| Mac | Model | State | Prefill tok/s | Decode tok/s | Request | Lowest free | Lowest file-backed | Pressure | Compressed | Swapped out |
|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|
| A | 27B, cut 16 | cache full | 271.9 | 28.5 | 35.3 s | 0.10 GiB | 138.6 GiB | normal | 0 | 0 |
| A | 27B, cut 16 | 58 GiB free | 299.3 | 28.7 | 32.5 s | 40.1 | 98.5 | normal | 0 | 0 |
| A | 9B, cut 4 | cache full | 1,010.3 | 70.3 | 9.3 s | 0.11 | 149.1 | normal | 0 | 0 |
| B | 27B, cut 16 | cache full | 636.1, 746.1, 758.6 | 27.0, 27.0, 26.9 | 18.2, 16.3, 16.1 s | 0.11 | 64.5 | normal | 0.09 GiB, 0, 0 | 0 |
| B | 27B, cut 16 | 18–27 GiB free | 810.0, 788.6, 797.2 | 27.2, 27.2, 27.1 | 15.4, 15.7, 15.6 s | 0.8–9.5 | 55.6–64.4 | normal | 0 | 0 |
| B | 9B, cut 4 | cache full | 2,710.6 | 76.5 | 4.1 s | 0.12 | 75.5 | normal | 0.25 GiB | 0 |

All stage models were released in every run (7,992 B and 4,024 B active
afterwards, 0 cached). The 27B result with the cache full is `exact` against
the same request under version 2 with free memory earlier that night, and
against the free-memory run of this build, on each Mac. Version 2 refused
both models' references in the cache-full state.

On Mac B two reference runs coincided with a little compression (0.09 and
0.25 GiB of pages; the compressor grew from 1.67 to 1.78 GiB over the whole
session). Nothing was swapped out and pressure stayed normal. No stage load,
no held load and no run on Mac A compressed anything.

### A short state still refuses

Cache full, then loaded stages held resident one after another until the
gate refused. Nothing but real loads was used.

- **Mac B.** Two 27B rank-1 stages at cut 4 were admitted and held (25.3
  GiB). The third: `Resident load needs 17.86 GiB of admissible memory and
  has 8.49 GiB: 0.16 GiB free plus 8.33 GiB of file cache counted (three
  quarters of the 11.10 GiB above the 44.48 GiB reserve, at most 32.00 GiB;
  55.58 GiB file-backed)`. A 9B stage was refused too (needs 8.67 GiB, has
  8.48).
- **Mac A.** Four 27B stages were admitted and held (50.5 GiB). The fifth:
  `Resident load needs 17.86 GiB of admissible memory and has 9.13 GiB: 0.31
  GiB free plus 8.82 GiB of file cache counted (three quarters of the 11.76
  GiB above the 91.20 GiB reserve, at most 32.00 GiB; 102.96 GiB
  file-backed)`. One 9B stage was then admitted, and the next refused at the
  entry check (needs 6.00 GiB, has 5.88).

On both Macs: 0 GiB compressed, nothing swapped out, compressor size
unchanged, pressure normal in every sample, lowest free 0.10–0.12 GiB. The
refusals came while 56 GiB and 99 GiB were still file-backed: what remained
was the kernel's reserve plus less than the load needed. Every held stage
released and exited 0; 27 GiB (Mac B) and 58 GiB (Mac A) were free afterwards.

### Tests

Library: 41 tests in 7 suites (29 in 6 before), 12 of them on this rule.
Worker package and the qualification, capability and protocol checks pass
unchanged. Ten mutants of the policy (no cache counted, fraction, cap,
reserve, kernel-reported minimum, pressure condition, inactive pages in place
of file-backed, truly-free floor, 6 GiB floor, counter bounds) each fail at
least one test.

## Cost

- **Load time:** none measurable (table above).
- **Request speed with no free pages:** prefill was 9% lower on Mac A (one
  pair of runs) and 5% lower on Mac B (two pairs), with one Mac B run 21%
  lower; decode about 1% lower. Every buffer a request allocates has to be taken
  from the cache first. That is the price of running in this state at all;
  version 2 did not run.
- **The gate itself:** one more sysctl read per decision, about 8,300
  decisions in a 27B stage load. No difference in load time between the
  versions was visible.

## Residual risk

- Measured on two Macs with 128 and 256 GB. On a small Mac the reserve (37%
  of pageable memory) is large against a stage: a 48 GB Mac that has just
  downloaded the 27B would still be refused rank 1 at cut 16. That is a
  refusal, not a hazard, but it is not the fix for that machine.
- The reserve follows a kernel formula read from XNU source and matched
  against `vm.vm_page_filecache_min` on macOS 27.0 and 27.2. Another macOS
  version may differ; the kernel-reported value is used when it is larger,
  not when it is smaller.
- File-backed pages are counted whether clean or dirty; the kernel publishes
  no split. The quarter left uncounted is the allowance.
- Pressure level is the only live signal that the kernel has started to
  struggle, and it moves late on a Mac with this much memory. The small
  compression seen during two reference runs on Mac B would not have moved
  it. A guard on compressor growth is the next step if that ever grows.
- A request that runs with no free pages prefills 5–21% slower. Nothing here
  warns the operator of that.
- The held-load proof drew file cache down to the reserve; it did not find
  where compression begins, which is somewhere below it. The rule's margin
  beyond the reserve is therefore unknown, not zero.
- Other processes can take the same cache between the sample and the use.
  The re-check at every tensor bounds the exposure to one tensor (at most
  0.6 GiB for the 27B) plus the 4 GiB headroom already in the requirement.
