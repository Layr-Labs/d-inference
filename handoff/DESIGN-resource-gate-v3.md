# Host memory gate, version 3: counting file cache, with a compression guard

> 2026-10-09, branch `work/resource-gate-v3`. Second edition, rewritten after an
> independent review of the first. "Mac A" is the M3 Ultra (256 GB, macOS
> 27.2), "Mac B" the M5 Max (128 GB, macOS 27.0). Raw samples are outside the
> repository in the task's evidence folders `gate-v3-20261009` (first round)
> and `gate-v3r2-20261009` (this round).

## Where this stands

The gate admits a load or a request on free pages plus part of the file cache.
That is a bet that the kernel can drop cached files without touching anonymous
memory. On these two Macs the bet holds when the cache is made of closed
files, and fails when the cache is mapped by a live process. The gate cannot
tell those apart before it starts. What it has is two bounds taken from the
kernel's own rules, which are necessary and not sufficient, and a guard that
withdraws the cache once the Mac is seen compressing.

Shown on hardware, on the commits of this branch:

- With the cache full of closed files, 27B and 9B stages load and 8,192-token
  references run on both Macs with nothing compressed and nothing swapped out.
- With the cache mapped by another process, the guard stopped the load on
  Mac B after about 0.55 GiB had been compressed, three times out of three,
  and the stage was released. On Mac A one load in that state compressed
  0.43 GiB, which is under the guard's limit, and completed.
- Two loads started together against a cache that has room for one are both
  refused, on Mac B part-way through, and both release; retried together they
  are refused again; one alone completes.

Not shown, and not to be assumed:

- Anything about a Mac other than these two, or about these two in a state
  not listed here.
- That a stopped load is harmless. Each attempt in the mapped-cache state
  costs other programs about 0.55 GiB of compressed memory, and nothing
  limits how often a supervisor retries.
- That the bounds predict what the kernel will do. They did not in the
  mapped-cache state.

Reviewer's verdict on the first edition, which still applies: safe to keep on
the experimental branch; not to be relied on beyond these two Macs in the
measured states.

## The problem

The resident load gate, the request gate and the diagnostics gate admitted on
actual free pages only (`registered_dense_selected_stage_load_resources_v2`):
at least 6 GiB free, and during a load the remaining tensors plus two host
copies plus 4 GiB. macOS keeps almost nothing free once files have been read.
After a model download or a hash pass a Mac holds a few hundred MiB free and
tens of GiB of file cache, so the product refuses its own first start. Both
Macs were in that state for most of a night and refused 27B loads, 8,192-token
requests and the single-Mac reference.

## What the kernel does

Read from the XNU source (`apple-oss-distributions/xnu`, `main`), and checked
against these Macs where a check was possible.

1. **Closed files are dropped whole.** Before it picks single pages,
   `vm_pageout_scan` calls `vm_object_cache_evict(100, 10)`, which frees the
   pages of files nobody has open or mapped. A file becomes eligible ten
   seconds after its last close or unmap (`#define EVICT_AGE 10`,
   `object->vo_cache_ts = sec + EVICT_AGE` in `osfmk/vm/vm_object.c`). No
   anonymous page is involved.
2. **Otherwise pages are picked one at a time**, in `vps_choose_victim_page`
   (`osfmk/vm/vm_pageout.c`):

   ```c
   inactive_external_count = vm_page_inactive_count - vm_page_anonymous_count;

   if ((vm_page_pageable_external_count < vm_pageout_state.vm_page_filecache_min || force_anonymous == TRUE) ||
       (inactive_external_count < VM_PAGE_INACTIVE_TARGET(vm_page_pageable_external_count))) {
           *grab_anonymous = TRUE;
           *anons_grabbed = 0;
           ...
   }
   *grab_anonymous = (vm_page_anonymous_count > vm_page_anonymous_min);
   ```

   with `#define VM_PAGE_INACTIVE_TARGET(avail) ((avail) * 1 / 2)`,
   `vm_page_anonymous_min = vm_page_inactive_target / 20` and
   `#define ANONS_GRABBED_LIMIT 2`. So anonymous pages, which means the
   compressor, are taken:
   - always, once file-backed memory is below the file-cache minimum;
   - always, once fewer than half of the file-backed pages are inactive;
   - and otherwise up to two for every file page, for as long as the inactive
     anonymous queue is longer than a twentieth of the inactive target.

   The third case is the one the first edition missed: above the minimum the
   kernel still compresses whenever it has to pick pages one at a time.
3. **The minimum** is `vps_calculate_filecache_min`: (active + inactive + free
   + speculative) × 10 / 27 on macOS, recomputed when the scan runs. The
   published `vm.vm_page_filecache_min` was within 1 % of that formula in the
   samples taken while the scan was running (3 % in one, taken while a request
   was wiring weights), and up to 15 % off between scans.
4. **An inactive page that has been read again is not freed but put back on
   the active queue.** "Inactive file-backed" is therefore an upper bound on
   what can be freed, not the amount.
5. **`host_statistics64` is answered from a cache for a binary that is not
   Apple's** (`osfmk/kern/host.c`: `HOST_STATISTICS_TIME_WINDOW 1`,
   `HOST_STATISTICS_MAX_REQUESTS 10`, `HOST_STATISTICS_MIN_REQUESTS 2`,
   "Access control only for third party applications"). After between two and
   ten calls inside one second the kernel returns the previous answer until
   the second is over. Measured on Mac A with an ad hoc signed binary: 2.17
   million calls in 4 s returned 11 different answers, at 0.35, 1.35, 2.35 and
   3.35 s; one call every 0.5 s was always fresh. The gate asks before every
   tensor, several thousand times a second, so the queue counters it sees are
   up to a second old. A sysctl read is not cached (22,126 different values of
   `vm.page_free_count` in 2 s from the same binary).

## What the first round measured, and what that was

Read-only sampling of `host_statistics64(HOST_VM_INFO64)`, the pressure level
and swap usage every 0.2 s around real stage loads. The cache was filled the
ordinary way, by reading existing model files until free pages ran out. A
measurement-only build skipped the free-page comparisons; it was never
committed (the patch is kept with the first round's evidence).

While a stage is idle its weights are anonymous pages of the loading process.
During a request they are wired: wired memory rose from 7.4 to 23.5 GiB on
Mac A and from 5.0 to 21.3 GiB on Mac B in every 27B reference run.

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

The v2 gate refused all four stages in that state. Seven of the eight loads
compressed nothing; the first compressed 51 MiB. Nothing was swapped out.
After release the weights' pages became free pages; the cache did not come
back by itself.

### How far the cache was drawn

Loaded stages were held resident one after another: 27B rank-1 stages at
cut 4 (12.6 GiB each), then 9B rank-1 stages (3.7 GiB each), down to the
kernel's file-cache minimum and two 9B stages past it. Mac B (2.81 GiB of
swap was in use throughout, from before the run):

| Held | File-backed | Kernel file-cache minimum | Above minimum | Anonymous | Inactive | Compressor | Pressure |
|---|---:|---:|---:|---:|---:|---:|---|
| nothing (cache full) | 80.9 GiB | 44.5 GiB | +36.4 | 39.0 | 87.8 | 1.51 | normal |
| 1 × 27B | 67.8 | 44.5 | +23.3 | 52.0 | 74.6 | 1.51 | normal |
| 2 × 27B | 55.0 | 44.5 | +10.5 | 65.3 | 61.9 | 1.51 | normal |
| + 2 × 9B | 46.0 | 44.6 | +1.4 | 74.1 | 60.0 | 1.51 | normal |
| + 3 × 9B | 41.7 | 44.5 | −2.8 | 78.4 | 60.1 | 1.51 | normal |
| + 4 × 9B (43.5 GiB held) | 37.5 | 44.5 | −7.0 | 82.6 | 60.0 | 1.51 | normal |

Nothing compressed, nothing swapped out, pressure normal in all 383 samples,
lowest free 0.26 GiB. All six processes released and exited 0.

Mac A, the same procedure (four 27B stages, then four 9B stages):

| Held | File-backed | Kernel file-cache minimum | Above minimum | Anonymous | Inactive | Compressor | Pressure |
|---|---:|---:|---:|---:|---:|---:|---|
| nothing (cache full) | 156.2 GiB | 91.4 GiB | +64.9 | 90.3 | 203.9 | 1.05 | normal |
| 2 × 27B | 129.8 | 91.4 | +38.4 | 116.0 | 178.2 | 1.05 | normal |
| 4 × 27B | 102.9 | 91.2 | +11.7 | 142.9 | 151.4 | 1.05 | normal |
| + 2 × 9B | 94.3 | 91.2 | +3.1 | 151.9 | 142.8 | 1.05 | normal |
| + 3 × 9B | 90.8 | 91.4 | −0.6 | 155.4 | 139.3 | 1.05 | normal |
| + 4 × 9B (65.3 GiB held) | 85.7 | 91.0 | −5.4 | 160.1 | 134.1 | 1.05 | normal |

Nothing compressed, nothing swapped out (Mac A has no swap in use), pressure
normal in all 463 samples, lowest free 0.10 GiB, all eight processes released
and exited 0. While the stages were still held, 44 GiB of file-backed memory
became free pages within one second and 49 GiB within ten, with no consumer
and with the pageout scan's page counters not moving. That is what the kernel
dropping whole closed files looks like, and also what deleting cached files
looks like; which of the two it was is not known.

### What those runs exercised

Over the 42 sampled runs of the first round (1,459 s) the pageout scan's own
page-by-page counters account for at most 0.2 GiB in any run, while 193 GiB of
file cache was given up in the 38 load and reference runs alone. The cache
went by another route, which the first mechanism above explains: closed files
dropped whole. The second mechanism, the one the rule's bounds describe, was
hardly exercised.

Where it was exercised it compressed. Three runs compressed anything at all:
51 MiB (Mac A, the first load above), 92 MiB and 255 MiB (Mac B, a 27B and a
9B reference run in the proof). In each the scan freed a similar amount of
file pages one at a time (145, 80 and 200 MiB) in the same samples. The other
39 runs (1,384 s) compressed nothing. Nothing was swapped out in any run.

So the first edition's central sentence, that file cache above the kernel's
minimum is "what the kernel gives up before it touches anonymous memory", was
not supported. What the runs showed is that a cache of closed files is given
up without touching anonymous memory, on these two Macs.

## The rule

Admissible memory for a decision that needs `required` bytes, for one load or
one request that took its first sample earlier:

```
pageable   = active + inactive + free (speculative included)
reserve    = max(pageable × 10 / 27 rounded up, kernel-reported minimum if readable)
above      = max(0, file-backed − reserve)
before     = max(0, 2 × inactive file-backed − file-backed)        0 if not reported
harmed     = compressed since first sample > 512 MiB
             ∨ swapped out since first sample > 64 MiB
counted    = 0                                 unless pressure is normal and not harmed
           = min(32 GiB, ¾ × min(above, before))
admissible = actual free + counted
admit      ⇔ observation valid
             ∧ actual free ≥ 16 MiB
             ∧ admissible ≥ max(6 GiB, required)
```

- **Reserve (first kernel bound).** The kernel's file-cache minimum, computed
  from the same snapshot with the kernel's formula, and the kernel-reported
  value when that is larger. Below it the kernel takes anonymous pages
  outright.
- **Before half is active (second kernel bound).** Taking `x` inactive file
  pages leaves `inactive − x` of `file − x`; that is fewer than half once
  `x > 2 × inactive − file`. `inactive_external_count` and
  `external_page_count` are the kernel's own two operands
  (`active_external + inactive_external + speculative = external` on both
  Macs). A kernel that does not report the inactive count counts no cache.
- **Three quarters** of the smaller bound. One quarter is left for pages that
  cannot be dropped at once and for other processes allocating between the
  sample and the use. It is margin, not a measured loss.
- **32 GiB cap.** A judgement, not a measurement: about half of the 64.9 GiB
  Mac A gave up above its minimum. In the first round Mac B never reached the
  cap (36.4 GiB above the minimum, 27 GiB counted); in this round it did,
  with 62 GiB above the minimum once most of its anonymous memory was in the
  compressor. The first edition derived the cap from a 43.5 GiB draw on Mac
  B; 7 GiB of that was below the minimum and should not have been used.
- **The guard.** Every load and every request keeps the compression and
  swap-out counters of its first sample. Once more than 512 MiB has been
  compressed or more than 64 MiB swapped out since then, no file cache is
  counted for it. It then stops at its next check, unless free pages alone
  cover what it still needs, in which case it was not relying on the cache.
  512 MiB is twice the largest amount compressed in any of the 42 first-round
  runs (255 MiB); 39 of them compressed nothing. Swap-outs never moved, so
  64 MiB is simply small. Compression is read from
  `vm.pageout_inactive_dirty_internal` and swap from `vm.swapusage`, by
  sysctl, because the statistics call is cached (point 5 above); the larger of
  the live and the cached figure is used. The two compression counters agreed
  to 0.01 % over days of uptime on both Macs.
- **Pressure** is a last-resort condition and not a detector of harm. On Mac
  B 18.4 GiB was compressed in two minutes with
  `kern.memorystatus_vm_pressure_level` at normal the whole time (see "Cache
  mapped and read by another process"). Cache is not counted at warning, and
  critical pressure is not judged at all, as before; neither can be expected
  to fire before the damage on a Mac of this size.
- **16 MiB truly free.** About the kernel's reserved pool on both Macs (914
  and 924 pages). The lowest free count in any run that completed was 98 MiB,
  so a floor anywhere up to about 90 MiB would have admitted the same runs;
  16 MiB was chosen as the kernel's own figure, not derived. Its sample can be
  a second old, so it is a weak tripwire.
- **6 GiB floor:** unchanged in size, on admissible memory.
- **A refusal that waiting cannot cure says so.** If the requirement exceeds
  free pages plus the most this Mac could ever count with its anonymous
  memory as it is (every other pageable page inactive file cache), the
  sentence ends: "More file cache cannot change this: with … of anonymous
  memory in use this Mac can count at most …, so … of the requirement has to
  be free pages".
- **Unchanged:** the swap-under-pressure refusal, critical pressure, stale or
  inconsistent observations, every allocator-limit comparison, the per-tensor
  and 250 ms re-checks, the requirement formulas at the three call sites.

What a re-check sees: the pressure level, the swap in use, the kernel's
minimum and the compression counter are current at every check. The queue
counters (free, file-backed, inactive, anonymous) are refreshed by the kernel
a few times a second; between refreshes a check sees the same figures again.
A 27B stage materializes in about 1.3 s on Mac B, so most of a load runs on
one or two snapshots of the queues. The first edition's sentence "every
re-check is a fresh sample" was wrong, and it was equally wrong of version 2.

### Small Macs: a documented limit

The reserve is 37 % of pageable memory, so on a small Mac little cache is
ever countable. With a requirement of stage + 5 GiB and 0.2 GiB free, in the
best case (every pageable page that is not anonymous is inactive file cache),
a stage is admitted only if anonymous memory is at most:

| Mac | 4 GiB stage | 10 GiB stage | 14 GiB stage |
|---|---:|---:|---:|
| 32 GB | 5.7 GiB | never | never |
| 48 GB | 15.5 GiB | 7.5 GiB | 2.1 GiB |
| 64 GB | 25.2 GiB | 17.2 GiB | 11.9 GiB |
| 128 GB | 63.6 GiB | 55.6 GiB | 50.3 GiB |

(The reviewer's table; the test suite reproduces the 32 GB row with a
constructed Mac.) A 32 GB Mac that has just downloaded the 27B is refused
rank 1 whatever it does with its cache, and is now told that waiting will not
help. That is a refusal, not a hazard, and this change is not the fix for
that machine.

### Rejected

- **Counting inactive pages** (what the ordinary provider does by default).
  On Mac A 102 GiB was anonymous and most of it inactive.
- **A flat fraction of file-backed pages.** It ignores both kernel bounds.
- **Purgeable pages.** 0.2–1.8 GiB on these Macs.
- **Speculative pages as a separate term.** They are file-backed and already
  inside the counted quantity.
- **The sysctl alone for the reserve.** It was 10 GiB stale at the moment a
  decision would have been taken.
- **Waiting and re-sampling, or reclaiming explicitly.** The cache-heavy
  state does not resolve by waiting, and a product that allocates memory to
  evict cache is the workaround this replaces.
- **Telling closed-file cache from mapped cache before admitting.** The
  kernel publishes no count of either. This is the gap the guard covers.
- **A reservation shared between processes**, so that two loads cannot count
  the same cache. Not built; a separate decision (see "Two loads started
  together").

## Where it lives

`QwenDenseStageLoadPolicy` decides and names the numbers in a refusal.
`QwenDenseStageLoadResources.observeOS()` samples. Each of the three gates
owns a `QwenDenseStageLoadWatch`: it keeps the first sample of its load or
request, asks the policy once per gate pass, throws a refusal as the policy's
sentence, and keeps a record (passes judged, refused, not judged, first,
tightest, fewest free pages, latest, compressed and swapped out since the
first sample). `QwenResidentResourceAdmissionReport.current` is every load's
and request's record of the calling process; the stage check and the
reference print it in their receipts, and a caller on the serving path can
print `current.lines` after a load or a request. Nothing on the serving path
prints it yet.

A load that fails part-way: the stage check and the reference now measure
active and cached bytes after releasing it and report them with the failure,
and their "model released" answer is real, because the loader hands them the
model when it is built. The resident load path
(`Resident/QwenResidentRuntime+Load.swift`) still takes its weak reference
from the loaded stage, so its "failed-load model remains retained" check
cannot fail for a load that stops part-way. That file was not this work's to
edit; the change is two lines:

```swift
-                        let value = try loadQwenResidentStage(admission, check: checked)
-                        retired = value.loaded.model; stage = value
+                        let value = try loadQwenResidentStage(admission, check: checked, constructed: { retired = $0 })
+                        stage = value
```

## Adverse states

All with the gate as built, no override, binaries of this branch. Memory was
shaped only by ordinary file reads and read-only maps. Counters sampled every
0.2 s from outside the process; "gate" figures are from the receipt.

### The cache holds the model being loaded

Other files read until free pages ran out, the artifact hashed (`shasum`,
which then exits), then the stage loaded while the loader holds every file of
the artifact open.

| Mac | Stage | Free before | File-backed | Inactive file-backed | Load | Compressed | Swapped out | Guard | After release |
|---|---|---:|---:|---:|---:|---:|---:|---|---|
| B | 27B rank 1, cut 16 | 0.17 GiB | 104.1 GiB | 101.0 GiB | 6.78 s | 0 | 0 | not reached | 0.01 MiB active, released |
| B | same, hashed again, no refill | 10.70 | 93.4 | 90.2 | 6.79 s | 0 | 0 | not reached | same |
| B | 9B rank 1, cut 4 | 5.25 | 98.9 | 95.8 | 2.64 s | 0 | 0 | not reached | 0 MiB active, released |
| A | 27B rank 1, cut 16 | 5.71 | 143.6 | 135.0 | 9.58 s | 0 | 0 | not reached | 0.01 MiB active, released |
| A | same, hashed again, no refill | 9.70 | 140.2 | 130.3 | 9.72 s | 0 | 0 | not reached | same |
| A | 9B rank 1, cut 4 | 5.73 | 144.6 | 134.7 | 3.67 s | 0 | 0 | not reached | 0 MiB active, released |

No harm. The kernel had 89 GiB (Mac B) and 128 GiB (Mac A) of other closed files to drop, so these
runs do not show whether it could have dropped the artifact's own pages while
the loader held its files open. (From the source, a descriptor that is not a
mapping should not take a file off the list of droppable files; that is a
reading, not a measurement.) What happens when the artifact is the only cache
there is was not tested: on these Macs that state cannot be produced with the
reserve satisfied.

### The cache mapped and read by another process

An ordinary process mapped 88.6 GiB of the cached files read-only, read one
byte of every page through the maps and stayed alive. This is the state of a
Mac on which another program is using large mapped files. Run on Mac B only,
with the first build of this round.

The state did the damage, before any load was asked for. Reading through a
map puts the page on the active queue; inactive file-backed memory fell from
81.0 to 40.4 GiB of 96.9, which is below half. From then on the kernel took
anonymous pages for every demand:

| Step on Mac B | Compressed in that step | Anonymous memory resident after it |
|---|---:|---:|
| before | | 29.7 GiB |
| the process maps and reads 88.6 GiB (48 s) | 5.3 GiB | 20.1 |
| one refused stage load | 0.05 | 20.3 |
| `shasum` of the 15.2 GiB artifact, maps still held (29 s) | 12.5 | 6.7 |
| second process maps and keeps reading for 40 s | 0.5 | 6.8 |

18.4 GiB compressed, 23 GiB of other programs' memory moved into the
compressor, nothing swapped out, and the pressure level normal in every
sample. This was the experiment's doing, not the gate's, and it is the cost
of having run it: that memory comes back when its owners touch it.

The gate refused all three loads in that state, on the second bound:
`Selected-stage loading needs 6.00 GiB of admissible memory and has 0.20 GiB:
0.20 GiB free plus 0.00 GiB of file cache counted (three quarters of the 0.00
GiB the kernel can take before anonymous memory: 53.48 GiB above the 43.43
GiB reserve, 0.00 GiB before half of the cache is active; at most 32.00 GiB;
96.92 GiB file-backed)`. The first edition's rule would have counted 32 GiB
there and admitted.

It is also conservative afterwards. Once the mapping process had exited the
cache was still half active and the gate went on refusing (1.0 GiB counted),
although the files were closed again; another worker's loads on Mac B four
minutes later took 10 GiB out of that cache with nothing compressed. Reading
the files once more in the ordinary way (95 GiB, 0 MiB compressed) put 96.8
of 99.6 GiB back on the inactive queue.

This case was not repeated on Mac A.

### The cache mapped by another process that reads nothing through its maps

Other files read, the artifact hashed, then an ordinary process mapped every
one of the other files (103.2 GiB) read-only and touched nothing. The pages
stay inactive, so both bounds are satisfied and the gate admits; but a mapped
file cannot be dropped whole, and the artifact's own files were closed less
than ten seconds earlier. Nothing is left for the first mechanism.

| Mac | Attempt | Free before | Counted | Loaded before the stop | Compressed (system) | Compressed (gate, at the stop) | Swapped out | Stopped by the guard | Wall | After release |
|---|---|---:|---:|---:|---:|---:|---:|---|---:|---|
| B | 1 | 0.19 GiB | 32.0 GiB | 5.6 GiB of 10.24 | 600 MiB | 564 MiB | 0 | yes | 6.5 s | 0 MiB active, released |
| B | 2, at once | 6.43 | 32.0 | 5.9 GiB | 567 MiB | 553 MiB | 0 | yes | 6.5 s | same |
| B | 3, mapping process just exited | 6.79 | 32.0 | 6.1 GiB | 556 MiB | 539 MiB | 0 | yes | 6.6 s | same |
| A | 1 (the only one) | 0.44 | 32.0 | all 10.24 GiB: completed in 9.6 s | 439 MiB | 439 MiB | 0 | no: under the limit | 9.8 s | 0.01 MiB active, released |

The refusal on Mac B: `Resident load needs 9.88 GiB of admissible memory and
has 0.11 GiB: 0.11 GiB free plus no file cache: 564 MiB was compressed and 0
MiB swapped out since its first check (limits 512 and 64 MiB), so the kernel
is taking anonymous memory`. This is the first time the mid-load stop and
release ran on hardware.

On Mac A the same state cost 439 MiB of compression and the load completed.
The first 8 GiB came out of cached files the mapping process did not hold
(it mapped the model caches, not every cached file on that Mac) with nothing
compressed; the last 2 GiB came page by page in 0.6 s, 0.44 GiB of it from
anonymous memory. That is under the limit, so the guard did not act; a longer
load would have reached it. One attempt only was made on Mac A.

Four things follow.

- Harm below the limit is tolerated by design: a load in this state can cost
  other programs up to 512 MiB and finish.
- On Mac B the guard is what protected the Mac. The bounds said 91–98 GiB
  could go before anonymous memory.
- A stop is not free: about 0.55 GiB of other programs' memory per attempt,
  1.7 GiB for the three. A supervisor that retries in this state compresses
  that much every time, without end. The guard's first sample is per load; a
  limit across attempts would have to live outside the process.
- The third attempt failed although the mapping process was gone: its files
  had been unmapped for less than ten seconds. The same load two minutes
  later compressed nothing.

The same case with the first build of this round, which read the compression
counter from the cached statistics, shows what the guard is worth without the
live counter. Attempt 1 was stopped at 1,061 MiB instead of 564. In attempt 2
the kernel moved 44 GiB of file pages from the inactive to the active queue
in 0.4 s (they had been read twice), which left exactly half of the cache
inactive, and then compressed 10.1 GiB in one second, most of it the stage's
own freshly loaded weights. The gate saw none of it until the next refresh
and stopped the load when it was nearly complete. That run is the evidence
for points 4 and 5 of "What the kernel does".

### Two loads started together

Two processes, the same stage, started within milliseconds against one cache.

| Mac | State | Counted at the start, each | Needed at the start, each | Outcome | Compressed | After release |
|---|---|---:|---:|---|---:|---|
| B | cache full | 32.0 GiB | 15.46 GiB | both completed, 7.18 s | 0 | released |
| B | three 27B stages held (37.9 GiB), 22.3 GiB above the reserve | 16.6 | 15.46 | both stopped after loading 6.27 GiB each | 0 | 0 MiB active, both released |
| B | the same two again, at once | 6.2 (+14.1 free) | 15.46 | both stopped after 6.38 GiB each | 0 | same |
| B | one of them alone, then | 6.0 (+14.2 free) | 15.46 | completed, 6.86 s | 0 | released |
| A | cache full | 32.0 | 15.46 | both completed, 9.83 s | 0 | released |
| A | four 27B stages held (50.5 GiB), 7 GiB above the reserve; cut 60 (1.46 GiB) | 5.2 | 6.66 | both refused at their first pass | 0 | 0 MiB active, both released |
| A | the same two again, at once | 5.4 (+1.2 free) | 6.66 | both refused at their third pass | 0 | same |
| A | one of them alone, then | 5.6 (+2.3 free) | 6.66 | completed, 7.98 s | 0 | released |

On Mac B each load was admitted on the same cache, which could hold one of
them and part of the other. Both then ran until the next refresh of the statistics
showed the cache they had jointly used up, and both were refused at the same
check (2,421 passes each, then 2,493 each): `Resident load needs 9.19 GiB of
admissible memory and has 6.34 GiB: 0.16 GiB free plus 6.17 GiB of file cache
counted …`. Both released everything. Nothing was compressed, because the
cache was closed files.

Started together again they fail again, the same few GiB in. One alone
completes. On Mac A the script held one stage more than intended, which left
room for one small stage only: the two were refused at their first and third
passes instead of part-way, and one alone completed. So a supervisor that restarts both ranks together can retry
forever in this state, and one that starts them one after the other succeeds.
Nothing in this change prevents the first. A reservation shared between the
processes would; it was not built and is a separate decision.

## Proof on hardware

The rule as committed on this branch, no override. "Cache full" means free
pages were exhausted by reading model files with `cat`. The binaries are the
ones built from the tree of commit `95b600957`; the build from the branch tip
is compared with them in the evidence (`commit-verification.txt`).

### Stage loads (rank 1, the large stage)

| Mac | Stage | State | Load | Admitted on | Above reserve / before half active | Compressed | Swapped out | After release |
|---|---|---|---:|---|---|---:|---:|---|
| B | 27B, cut 16 (10.24 GiB) | cache full | 6.84 s, 6.95 s | free 0.1–0.2 + cache 32.0 (cap) for 15.46 GiB | 61.8 / 97.8 GiB | 0 | 0 | 0.01 MiB active, released |
| B | same | 53 GiB free | 6.81 s | free pages alone | 7.8 / 42.0 | 0 | 0 | same |
| B | 9B, cut 4 (3.71 GiB) | cache full | 3.32 s, 3.32 s | free 0.2–1.9 + cache 32.0 for 8.68 GiB | 59.3–61.1 / 92.9–94.9 | 0 | 0 | 0 MiB active, released |
| B | same | 53 GiB free | 3.32 s | free pages alone | 7.8 / 42.0 | 0 | 0 | same |
| A | 27B, cut 16 | cache full | 13.91 s, 12.94 s | free 0.5–2.0 + cache 32.0 (cap) for 15.46 GiB | 57.9–60.9 / 128.2–134.5 | 0 | 0 | 0.01 MiB active, released |
| A | same | 52 GiB free | 12.99 s | free pages alone | 10.1 / 79.4 | 0 | 0 | same |
| A | 9B, cut 4 | cache full | 5.15 s, 5.08 s | free 1.0–1.3 + cache 32.0 for 8.68 GiB | 61.2–61.7 / 133.7–133.8 | 0 | 0 | 0 MiB active, released |
| A | same | 52 GiB free | 5.14 s | free pages alone | 10.1 / 79.2 | 0 | 0 | same |

A load takes one decision per gate pass: 4,155 for the 27B stage and 2,430
for the 9B stage, none refused, none unjudged.

### Single-Mac reference (8,192-token prompt, chunk 512, both stages in one process)

| Mac | Model | State | Prefill tok/s | Decode tok/s | Lowest free | Lowest file-backed | Peak wired | Compressed | Swapped out |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| B | 27B, cut 16 | cache full | 637.6 | 27.13 | 0.15 GiB | 85.8 GiB | 21.1 GiB | 0 | 0 |
| B | 27B, cut 16 | 53 GiB free | 808.7 | 27.20 | 36.2 | 50.1 | 21.2 | 0 | 0 |
| B | 9B, cut 4 | cache full | 2,753.1 | 77.10 | 0.17 | 96.5 | 10.7 | 0 | 0 |
| A | 27B, cut 16 | cache full | 271.8 | 27.70 | 0.10 | 130.1 | 23.3 | 0 | 0 |
| A | 27B, cut 16 | 52 GiB free | 299.9 | 28.07 | 34.6 | 101.3 | 23.3 | 0 | 0 |
| A | 9B, cut 4 | cache full | 1,016.6 | 71.35 | 0.11 | 146.3 | 13.9 | 0 | 0 |

Each reference has six records: two loads, two requests, two diagnostics
captures. For the 27B with the cache full: 1,392 and 4,155 load decisions on
either Mac, 40 and 40 request decisions and 43 and 43 diagnostics decisions on
Mac B, 54 and 54 and 57 and 57 on Mac A; none refused, none unjudged. All
stage models were released (7,992 B and 4,024 B active afterwards). On each
Mac the 27B result with the cache full is `exact` against the free-memory run
of this build, against the first round's free-memory run, and against the
same request under version 2; the 9B result is `exact` against the first
round's.

### A short state still refuses

Cache full, then loaded stages held resident one after another until the
gate refused. Nothing but real loads was used.

- **Mac B.** Three 27B rank-1 stages at cut 4 were admitted and held (37.9
  GiB). The fourth: `Resident load needs 17.86 GiB of admissible memory and
  has 15.77 GiB: 0.19 GiB free plus 15.58 GiB of file cache counted (three
  quarters of the 20.77 GiB the kernel can take before anonymous memory:
  20.77 GiB above the 42.40 GiB reserve, 55.11 GiB before half of the cache
  is active; at most 32.00 GiB; 63.18 GiB file-backed). More file cache
  cannot change this: …`. Three 9B stages were then admitted; the fourth was
  refused at the entry check (needs 6.00 GiB, has 5.96). Nothing compressed,
  nothing swapped out, pressure normal throughout; every held stage released;
  53 GiB free afterwards.
- **Mac A.** Three 27B stages were admitted and held (37.9 GiB). The fourth:
  `Resident load needs 17.86 GiB of admissible memory and has 17.21 GiB: 0.85
  GiB free plus 16.36 GiB of file cache counted (three quarters of the 21.81
  GiB the kernel can take before anonymous memory: 21.81 GiB above the 91.31
  GiB reserve, 92.82 GiB before half of the cache is active; at most 32.00
  GiB; 113.12 GiB file-backed). More file cache cannot change this: …`. Three
  9B stages were then admitted; the fourth was refused (needs 8.67 GiB, has
  7.12). Nothing compressed, nothing swapped out, pressure normal throughout;
  every held stage released; 52 GiB free afterwards.

Each refused load printed its failure record: 0 bytes active after release,
model released. (Mac B admitted three 27B stages here and two in the first
round because it had 28 GiB less anonymous memory resident: the mapped-cache
experiment had moved it into the compressor an hour earlier. Mac A admitted
three where the first round admitted four: it started with 2 GiB less cache
and the fourth missed by 0.65 GiB.)

### What the two changes do to the first edition's tables

- **One load with the cache full** (eight rows). The guard: the most any of
  those loads compressed was 51 MiB, a tenth of the limit; no row changes.
  The second bound: the inactive file-backed count was not recorded in the
  first round. In the same states now the second bound stood at 87–98 GiB on
  Mac B against 51–62 GiB above the reserve, and at 128–134 GiB on Mac A
  against 58–62, so the reserve is the smaller bound and no row changes.
- **How far the cache was drawn** (both Macs). Those runs used the override
  build and compressed nothing, so the guard changes nothing. In the re-run
  the second bound stayed the larger at every step down to the refusal (20.8
  against 55.1 GiB, then 7.8 against 42.0, on Mac B; 21.8 against 92.8, then
  8.4 against 78.2, on Mac A), so the refusal point is set by the reserve as
  before. The rows past the kernel's minimum were never
  admissible.
- **Stage loads, references, short state** (the first edition's proof). Re-run
  on this branch above, with the same outcomes: admitted with the cache full,
  refused in the short state, results `exact`. The first round's two Mac B
  reference runs that compressed 92 and 255 MiB would not have been stopped;
  the re-run compressed nothing.
- **What does change** is outside those tables: the gate now refuses a cache
  that is mostly active, and stops a load that the Mac answers by compressing.

### Tests

Library: 66 tests in 11 suites at the tip, 29 of them on this gate (the
first edition had 12): 24 on constructed observations and 5 against the real
counters. The worker package's 34 tests and the qualification, capability and
protocol checks pass unchanged. The pure-policy tests stand on: the exact
three-quarter limit, the cap, the reserve and one page above it, the reserve
rounded up to a whole page, a kernel minimum below, equal to and above the
computed one, speculative pages in the pageable sum, the second bound at
half, one page past half and unreported, the compression limit and one page
over it for both sources and for swap, a decision that free pages alone
cover, counters that ran backwards, the structural refusal on a 128 GiB and a
32 GiB Mac, warning and critical pressure, the truly-free floor, a requirement
equal to and above physical memory, file-backed and inactive counts that
exceed their totals, overflow, staleness, and the record (one decision per
pass, refusals thrown as their sentence, samples not judged, each watch's own
first sample, the bounded list). They do not cover the sampler's behaviour
under the kernel's cache: the test runner is an Apple binary and is not
served cached statistics.

Against the real counters, loading nothing: a sample is valid and judged;
file-backed plus anonymous equals the three queues; the kernel's minimum is
the formula; the sysctl compression counter is the statistics' one; each of
the three gates hands its sample to its own watch and compares no free-page
count itself. Two of these say in their output whether they were decisive on
the day: the comparison of the kernel's minimum is held to 3 % only if the
pageout scan ran during the test (20 % otherwise), and the end-to-end run of
the request gate tells the old comparison from the new only when the Mac is
short of free pages. In the run recorded with the proof Mac A had 112 GiB
free, so neither was.

## Cost

- **Load time:** none measurable. 27B stage on Mac B: 6.84 and 6.95 s with
  the cache full, 6.81 s with 53 GiB free; on Mac A: 13.91 and 12.94 s against
  12.99 s.
- **Request speed with no free pages:** prefill 21 % lower on Mac B in this
  round's one pair (637.6 against 808.7 tok/s) and 9 % lower on Mac A (271.8
  against 299.9); the first round saw 5 % and 21 % on Mac B and 9 % on Mac A.
  Decode within 1.5 %. Every buffer a
  request allocates has to be taken from the cache first. Nothing warns the
  operator of this.
- **The gate itself:** one statistics call and four sysctl reads per pass,
  4,155 passes in a 27B stage load.

## Residual risk

1. **The rule is a bet with a tripwire.** Nothing the gate can read says
   whether the cache is closed files. When it is not, the load starts, the
   Mac compresses about 0.55 GiB of other programs' memory, and the load is
   stopped. That was measured at 539–600 MiB on Mac B; on Mac A one load in
   that state compressed 439 MiB and, being under the limit, was not stopped.
   Neither is a bound the kernel guarantees.
2. **Retries multiply it.** The guard counts from each load's own first
   sample. A supervisor that retries a stopped load pays the same again each
   time, and two ranks restarted together fail together every time.
3. **The guard's limit is one figure from 42 runs on two Macs.** A Mac that
   compresses more than 512 MiB for unrelated reasons during a load, while
   short of free pages, has that load stopped. A Mac whose harm starts below
   512 MiB per load is not protected from it.
4. **The bounds are a second old.** Free, file-backed, inactive and anonymous
   counts are refreshed by the kernel a few times a second for this binary.
   Two loads can both be admitted on one snapshot, and a load can finish on
   a snapshot taken before another consumer arrived. The 4 GiB headroom and
   the quarter left uncounted are what stands against that, and the guard.
5. **Inactive is not freeable.** Inactive pages that were read twice are
   moved back to the active queue when the kernel reaches them. The second
   bound was 91.8 GiB a second before the kernel reached its limit.
6. **Recently closed files cannot be dropped for ten seconds.** A load that
   starts right after a large hash pass or after a mapping process exits
   depends on older cache being there.
7. **A cache that is in use refuses the product** (most of it active): the
   gate counts nothing and says so. So does a Mac on which such a process has
   just exited, until ordinary reading has turned the cache over. Version 2
   refused there too.
8. **Small Macs** are mostly refused (table above).
9. **Other macOS versions.** The reserve and the second bound follow XNU
   source read at `main` and checked on macOS 27.0 and 27.2. A test compares
   the published minimum with the formula on the Mac it runs on. The
   statistics structure must carry `inactive_external_count`; an older kernel
   counts no cache.
10. **Dirty and clean file pages are not told apart**; the kernel publishes no
    split. Nothing in these runs wrote to the cached files.
11. **Pressure level** is not a usable signal on Macs of this size (18.4 GiB
    compressed at normal).
12. **The serving path does not print the record.** The accessor exists; no
    caller uses it.
13. **The resident load path's released-model check** is still vacuous for a
    load that fails part-way (two-line change above, in a file this work did
    not own).
14. **A request that runs with no free pages** prefills 5–21 % slower.
