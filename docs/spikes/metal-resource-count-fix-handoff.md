# Metal resource-COUNT crash fix — how the upstream C++ was landed

> **STATUS (2026-06-15): LANDED.** The fork route (Option A below) was taken.
> `ml-explore/mlx` and `ml-explore/mlx-c` were forked into the org as
> `Layr-Labs/mlx` / `Layr-Labs/mlx-c`; the C++ fix was pushed there and pinned by
> SHA (also tagged `darkbloom-metal-resource-count` for permanence).
>
> Merged, bottom-up:
> - `Layr-Labs/mlx-c#1` → fix on the mlx-c fork
> - `Layr-Labs/mlx#1` → fix on the mlx fork (re-targeted onto a `darkbloom-base`
>   branch at the patch's upstream base `ce45c52`, since the fork's `main` was
>   153 commits ahead of what mlx-swift is built against)
> - `Layr-Labs/mlx-swift#4` → Swift surface (`Memory.numResources` / `.resourceLimit`)
> - `Layr-Labs/mlx-swift#5` → repoint `.gitmodules` to the forks + bump the Cmlx
>   gitlinks → un-breaks `mlx-swift main` (#4 alone left it with an undefined symbol)
> - `Layr-Labs/mlx-swift-lm#39` → env-gated `[rsrc]` telemetry
> - `Layr-Labs/d-inference#355` (this PR) → bump `libs/mlx-swift` → `ac67822`,
>   `libs/mlx-swift-lm` → `404afee`, plus the live probes + this doc
>
> The historical "decision" content below is kept for the record.

## What this fixes

Provider crash `[metal::malloc] Resource limit (499000) exceeded` during
continuous-batched decode on Apple Silicon (seen on the M3 Max / 128 GB box at
~39 GB RSS — most of RAM free, so NOT a byte OOM).

**Root cause:** MLX's `MetalAllocator::malloc` throws when `num_resources_` (the
live + cached Metal buffer COUNT) reaches `resource_limit_` (the
`iogpu.rsrc_limit` sysctl, default ~499000 — a COUNT, not bytes). Freed buffers
recycle into a size-keyed cache that is trimmed **only by bytes**
(`max_pool_size_` ≈ physical RAM). Under churn with many distinct buffer shapes
(varied prompt lengths, growing KV caches, co-resident models), the cache fills
with entries never reused at that exact size, so the COUNT climbs to the limit
while byte usage stays modest and the byte trim never fires → crash.

**Fix:** a count-aware reclaim in `malloc` — when `num_resources_` crosses 90% of
`resource_limit_`, clear the (pure-reuse) buffer cache so the count drops back to
the live working set. Plus `get_num_resources()`/`get_resource_limit()` telemetry
plumbed C++ → mlx-c → Swift, and an `MLX_RESOURCE_LIMIT` env override (lowers the
ceiling only; strictly validated) for tests / operator safety valve.

Validated: fork regression test `MemoryTests.testResourceCountStaysUnderLimitUnderChurn`
(byte-trim off, distinct-size churn, `MLX_RESOURCE_LIMIT=50000`) → peak 43,638 of
50,000, never reached the limit, no crash. Pre-fix the same load throws. Dual
review (Codex gpt-5.5 xhigh + independent Claude) PASSED.

## (historical) The blocker that needed a human decision

The C++ fix lives in **two nested submodules** of `Layr-Labs/mlx-swift` that point
at upstream Apple repos we can't push to:

| Submodule path | `.gitmodules` URL | What changed |
|---|---|---|
| `Source/Cmlx/mlx` | `https://github.com/ml-explore/mlx` | allocator.cpp/.h, memory.h, no_gpu+cuda stubs |
| `Source/Cmlx/mlx-c` | `https://github.com/ml-explore/mlx-c` | `mlx/c/memory.{cpp,h}` |

`Layr-Labs/mlx-swift` compiles these C++ sources directly from the submodule paths
(see its `Package.swift` `Cmlx` target). So the fix **cannot link** until the C++
lands somewhere pushable. The branch `fix/metal-resource-count-trim` on
`Layr-Labs/mlx-swift` carries only the owned files (umbrella header copy +
`Memory.swift` + test) and deliberately does **not** bump the submodule pointers.

The C++ fix has since been **pushed** (no longer local-only): it lives on the
Layr-Labs forks at `Layr-Labs/mlx@d5213411` and `Layr-Labs/mlx-c@bc48a1a`, each
also pinned by the immutable tag `darkbloom-metal-resource-count` and merged via
`Layr-Labs/mlx#1` / `Layr-Labs/mlx-c#1`. To recreate or inspect the C++ diff,
fetch those commits/tags from the forks — e.g.
`git fetch <fork> darkbloom-metal-resource-count && git show <tag>` — rather than
relying on any local patch file.

### Option A — fork ml-explore/mlx + ml-explore/mlx-c into Layr-Labs (cleanest)

1. Create `Layr-Labs/mlx` (fork of `ml-explore/mlx`) and `Layr-Labs/mlx-c`.
2. Push the local submodule branches to the forks:
   ```bash
   cd libs/mlx-swift/Source/Cmlx/mlx
   git remote add layr git@github.com:Layr-Labs/mlx.git
   git push layr fix/metal-resource-count-trim
   cd ../mlx-c
   git remote add layr git@github.com:Layr-Labs/mlx-c.git
   git push layr fix/metal-resource-count-trim
   ```
3. Re-point `Layr-Labs/mlx-swift`'s `.gitmodules` to the forks and bump the
   pointers (on the existing `fix/metal-resource-count-trim` branch):
   ```bash
   cd libs/mlx-swift
   git config -f .gitmodules submodule.submodules/mlx.url   git@github.com:Layr-Labs/mlx.git
   git config -f .gitmodules submodule.submodules/mlx-c.url git@github.com:Layr-Labs/mlx-c.git
   git add .gitmodules Source/Cmlx/mlx Source/Cmlx/mlx-c   # bump gitlinks
   git commit -m "Point Cmlx submodules at Layr-Labs forks with the resource-count fix"
   git push
   ```
   Pros: clean diffs, easy to rebase on future upstream mlx bumps. Cons: two new
   org repos to maintain; `.gitmodules` change propagates to everyone who clones.

### Option B — vendor the patch into Layr-Labs/mlx-swift (single repo, no fork)

Apply the two C++ patches as committed/vendored files inside `Layr-Labs/mlx-swift`
(or as a `patches/` dir applied in a build step), so the whole fix lives in one
repo we own. One PR, no upstream fork. Cons: heavier change to the fork's build
setup, diverges harder from upstream, every future mlx bump must re-apply.

## Merge ordering (strict — bottom-up; each layer needs the one below)

1. **C++** lands (Option A: forks merged + `mlx-swift` `.gitmodules`/pointers bumped;
   or Option B: vendored into `mlx-swift`). Until this, the symbols
   `mlx_get_num_resources` / `Memory.resourceLimit` don't exist.
2. **`Layr-Labs/mlx-swift#…`** (`fix/metal-resource-count-trim`) merges to `main`
   — owned files + (for Option A) the pointer bump. ⚠️ Its CI is RED until step 1
   is folded in, because `Memory.swift` calls the new C symbols.
3. **`Layr-Labs/mlx-swift-lm#…`** merges — only env-gated telemetry; it resolves
   `mlx-swift` via remote `main`, so it goes green once step 2 is on `main`.
4. **`Layr-Labs/d-inference#…`** merges last — bump `libs/mlx-swift` and
   `libs/mlx-swift-lm` submodule pointers to the merged commits, THEN the probe
   tests compile (they call `MLX.Memory.resourceLimit`). The probe PR currently
   pins the pre-fix `mlx-swift` (`5202134`), so **its CI is RED until the pointer
   bump** — that's expected, not a regression.

## Branches pushed (all `fix/metal-resource-count-trim`)

- `Layr-Labs/mlx-swift` — umbrella header + `Memory.swift` + `MemoryTests`
- `Layr-Labs/mlx-swift-lm` — `EngineCore` `[rsrc]` env-gated telemetry
- `Layr-Labs/d-inference` — provider `ContinuousBatchingLiveTests` probes

## C++ fix — pushed to the org forks (no longer local-only)

- `Layr-Labs/mlx@d5213411` — the allocator fix (count-aware cache trim); merged
  via `Layr-Labs/mlx#1`, tagged `darkbloom-metal-resource-count`.
- `Layr-Labs/mlx-c@bc48a1a` — the C wrappers; merged via `Layr-Labs/mlx-c#1`,
  tagged `darkbloom-metal-resource-count`.
- `Layr-Labs/mlx-swift@ac67822` repoints `.gitmodules` to these forks and pins
  the two commits.

## Operator safety valve (works today, no rebuild beyond the fix)

Once the fixed binary is deployed, `MLX_RESOURCE_LIMIT=<n>` (e.g. `250000`) pins
the count ceiling below the OS default so the 90% trim fires earlier — a knob if a
box still trends toward the limit. It can only LOWER the ceiling (clamped to the
OS value); junk/zero/negative values are ignored.
