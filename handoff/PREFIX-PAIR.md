# Prompt-prefix reuse on the pair, on by default

> Last updated: 2026-10-11 (SSD tier: branch `work/ssd-prefix-tier`, base `fa41f769d`)

"Mac A" is the M3 Ultra (256 GB), "Mac B" the M5 Max (128 GB). Raw logs and
reports are outside the repository in the task's evidence folder
`prefix-20261010`. Nothing here was pushed.

## Status

| Item | Status |
|---|---|
| Rank-local resident prefix reuse, dense Qwen (9B, 27B), pipeline and phase split | **Done, on by default**; measured across the cable (table below) |
| Agreement before the first forward; mismatch means a cold prefill on both ranks | **Done** (unit tests; every cable request agreed) |
| Provider: receipts, `cached_tokens`, frontiers published as resident evidence | **Done** (unit tests); not yet run through `darkbloom start` on the pair |
| SSD tier per rank (records survive a restarted pair) | **Built, on by default with the cache** (section "SSD tier"); cross-cable results in that section |
| Paged KV in the stages | **Not built**: blocked, see below |

## How it works

- **Cache.** Each rank keeps its own stage's committed state
  (`QwenStagePrefixCache`, `DarkbloomClusterRuntime/Models/Qwen/Prefix`). Both
  ranks use the same key: the agreed request scope (plan, artifact, storage,
  source configuration, arithmetic, profile, chunk size) plus the prompt tokens
  before the frontier. Least recently used goes first, by entry count (32),
  never by bytes. When the live memory check of a request or reservation would
  refuse, entries are dropped one at a time (and their buffers returned) until
  it passes; the cache never makes a request fail for memory.
- **Frames.** With the cache on, prefill starts at the reused prefix, chunks end
  on the global chunk grid (512), and the last prompt token runs in a frame of
  its own, so the state after N-1 tokens is an exact frame boundary for the
  hybrid recurrent layers. A hit always leaves at least one token to compute.
  Frontiers kept: every 512 grid end after the reused prefix, and N-1.
  Recurrent state is kept by reference (immutable confirmed arrays, as the
  product's hybrid checkpoints are); attention rows are copied once, at N-1,
  and shallower frontiers are views of that copy.
- **Agreement.** Before the first forward, two fixed 64-word exchanges over the
  collective (the same mechanism as the readiness digest). Each rank offers the
  frontiers it holds; both derive the same choice (the deepest frontier both
  hold; the split only if both caches are on). Each rank restores that frontier
  into a new session, then both confirm the choice, the key and the restore.
  Anything else and both drop what they restored and prefill from zero.
- **Lifecycle.** A rank inserts its captured frontiers only after both ranks
  retired the request cleanly. A failed request stores nothing and the rank
  sweeps its cache; shutdown sweeps before the model is released. A process
  that exits takes its cache with it, so a restarted pair starts cold.
- **Reporting.** Each worker sends `promptCache(reusedTokens, storedFrontiers)`
  just before `finished`. The owner requires rank 1's reuse to equal rank 0's,
  publishes the frontiers both hold, and the engine's terminal usage reports
  the hit (`prompt_tokens_details.cached_tokens`). The bridge mints a receipt
  per request and turns published frontiers into resident prefix evidence for
  routing.
- **Off switch (diagnosis only).** `DARKBLOOM_CLUSTER_PREFIX_CACHE=off` in a
  worker's environment. The installed owner passes it through from its own
  environment; `darkbloom-cluster-pair-check run --prefix-cache off`. One rank
  off is enough: neither rank splits or reuses.
- **Pair check.** `--follow-request FILE` (repeatable) runs further requests in
  the same loaded session; each request's report carries `reusedPromptTokens`,
  `storedPromptFrontiers` and its prompt digest.

## Measured across the cable, 2026-10-10

Rank 0 on Mac A (listener), rank 1 on Mac B, cut 16, chunk 512, 64 outputs,
greedy, serving path. "First" is a cold prompt with the cache on; "repeat" the
same prompt again; "shared" the same prompt with its last 256 tokens changed.
"Off" is a session with the switch off (no split, no reuse: the previous
behavior). Seconds to the first token; cached prompt tokens in brackets.

| Model, mode | Prompt | First | Repeat | Shared | Off |
|---|---|---|---|---|---|
| 9B pipeline | 8,192 | 5.70 | 0.030 (8,191) | 0.40 (7,680) | 5.62 |
| | 4,096 | 2.71 | 0.026 (4,095) | 0.37 (3,584) | 2.68 |
| | 1,024 | 0.67 | 0.024 (1,023) | 0.35 (512) | 0.66 |
| 9B phase split, lookahead | 8,192 | 4.10 | 0.083 (8,191) | 0.42 (7,680) | |
| | 4,096 | 2.03 | 0.045 (4,095) | 0.38 (3,584) | |
| | 1,024 | 0.59 | 0.041 (1,023) | 0.36 (512) | |
| 27B pipeline | 8,192 | 13.91 | 0.061 (8,191) | 0.98 (7,680) | 13.93 |
| | 4,096 | 6.83 | 0.054 (4,095) | 0.95 (3,584) | 7.14 |
| | 1,024 | 1.78 | 0.050 (1,023) | 0.93 (512) | 1.78 |
| 27B phase split, lookahead | 8,192 | 7.86 | 0.112 (8,191) | 1.03 (7,680) | |
| | 4,096 | 4.16 | 0.107 (4,095) | 1.04 (3,584) | |
| | 1,024 | 1.48 | 0.102 (1,023) | 1.02 (512) | |

The final build reproduced the 9B pipeline, 9B phase split and 27B pipeline
rows with identical tokens and first tokens within 2 %. The phase split rows
use the one-chunk lookahead prefill, so the pipeline's switch-off column is not
their cold baseline.

Output: in every row the repeat selected exactly the first request's tokens,
and the shared-prefix request exactly the tokens of the same prompt run cold
with the cache on. Splitting the last prompt token changes the arithmetic of
the final prefill frame: against the switch-off run some prompts diverge, at a
near tie (9B, 1,024 tokens, local socket: `divergedAtNearTie` at token 61,
1 ulp, against the staged reference, which equals the switch-off run
exactly). The split costs the 9B 13 to 82 ms on a cold first token; on the
27B the difference is inside run-to-run noise.

A fault (rank 1 ended with SIGTERM in the middle of a cache hit's decode)
failed that request; rank 0 exited by itself, no worker was left on either
Mac and wired memory returned; the next session served a cold and a repeated
request normally.

On Mac B, with about 45 GB of other applications resident, the 27B phase
split's decoding rank needs its full hand-off allowance: the first build of
the cache (no yielding) failed a request there on the live memory check after
the cache grew to 25 entries (about 3 GB on that rank). The cache now gives
entries back under that check; the rerun dropped 4 entries and completed.

## SSD tier

From the owner's design (oMLX `prompt_snapshot_cache.py`: per-rank boundary
chains, unanimous boundary vote, directories scoped by plan and rank, sweep on
every rank) and the product's SSD tier policies (encrypted at rest, keyed
names, 30-minute sliding TTL, free-space floor, daily write cap, write-behind
that never back-pressures serving). Code: `QwenStagePrefixDiskTier`,
`QwenStagePrefixDiskRecord`, `QwenStagePrefixDiskConfiguration`,
`QwenStagePrefixKeys` in `DarkbloomClusterRuntime/Models/Qwen/Prefix`.

- **Directories.** `<root>/v1-<digest>/rank<r>/`, the digest over the plan
  fingerprint, the verified artifact, the storage commitment, both ranks'
  builds, the generation mode and the prefill schedule. A re-split, another
  model, a new build or another mode is another directory. At load every rank
  deletes the other plans' directories under its root (only names the tier
  creates, and never one a live rank holds: each rank keeps a shared lock on
  its plan directory's `in-use` file). The off switch deletes them all.
- **Records.** One record per prompt per rank: this rank's attention rows up
  to N-1, stored in units of one 512-row block (all heads), and the recurrent
  state at N-1 and at each frontier on the disk grid (2,048 tokens, doubled
  until a record keeps at most 8 grid frontiers). A shallower frontier reads
  only its own units. Each record has its own random data key, wrapped with a
  key derived from the owner's key; every unit is AES-GCM sealed under a nonce
  made of its index; file names are keyed tags. A changed byte, a different
  key or a record of another prompt is an absent record (deleted).
- **Agreement.** The offer words carry a tier bit per frontier (magic
  `PFX3`). Both ranks choose the deepest frontier both hold in either tier and
  each restores from its own tier; the existing confirmation exchange makes
  it both or neither (a rank that cannot read its record makes both ranks
  prefill from zero). A frontier read from disk that both ranks confirmed
  becomes resident on both ranks. A record the stage cannot adopt is deleted.
- **Writes.** After both ranks retired a request cleanly, the rank prepares
  the record's bytes on the serving thread (no copy of contiguous arrays) and
  one serial writer seals and writes them behind serving (temporary file,
  then rename; caching off). At most 2 jobs / 4 GiB wait behind the writer;
  more is dropped, never waited for. Shutdown drains the queue (bounded) before
  the model is released; a killed writer leaves only a temporary file, deleted
  at the next load.
- **Limits.** Least recently used by record count (64 a rank; both ranks run
  the same operations, so they evict alike), then a byte budget (16 GiB a
  rank; a safety bound that may differ between ranks: a frontier one rank no
  longer holds is simply not chosen), a sliding TTL of 30 minutes (the
  product's ceiling; the switch can only shorten it), no writes below 20 GiB
  free or past 750 GB written in a day, and prompts under 1,024 tokens are not
  kept.
- **Configuration.** The worker reads `DARKBLOOM_CLUSTER_PREFIX_SSD_DIR` from
  its environment and its 32-byte key ONLY from its input: started with
  `--prefix-ssd-key darkbloom/prefix-ssd-key/input-line/v1` (the scheme, never
  the key), it reads one `prefixSSDKey` line (epoch- and rank-bound, base64
  key) right after the S16 data-plane credential, before the control reader
  starts. Without a directory and a key the tier is off and no prompt state
  touches the disk. A key in the environment is never used: a worker refuses
  to start when `DARKBLOOM_CLUSTER_PREFIX_SSD_KEY` or `..._KEY_FILE` is set
  (an environment is readable by every process of the same user for the
  process's whole life), and an owner refuses a worker binary that lacks the
  scheme while the tier is on (no fallback). The installed owner sets the
  directory and sends the key when the prefix cache is on: root
  `~/Library/Caches/darkbloom/cluster-prefix-v1` (beside the product's `kv3`,
  which it never touches) and this Mac's owner key, which outlives every
  owner process (an owner serves one session, and the records exist to warm
  the next one): derived from the product's Secure Enclave-rooted KEK when
  the build holds the keychain entitlement (the single-Mac SSD tier's key
  hierarchy; no new item or permission; never written), otherwise a random
  key published once in `~/.darkbloom/cluster-device/prefix-ssd-v1.key`
  (owner-only, never replaced; the owner reads it), and only if neither works
  a key of the owner process (records then last one session). A rank deletes
  every record a different key wrote.
  `DARKBLOOM_CLUSTER_PREFIX_SSD=off` turns it off for diagnosis; budget
  switches `..._MAX_GB`, `..._MAX_RECORDS`, `..._TTL_SECONDS`, `..._STRIDE`,
  `..._MIN_TOKENS`, `..._MAX_WRITE_GB_PER_DAY`, `..._MIN_FREE_GB` pass through.
- **Qualification.** `darkbloom-cluster-pair-check run` takes
  `--local/--remote-prefix-ssd-dir` and `--...-prefix-ssd-key-file` (the
  driver reads each side's key file there and sends the key on that worker's
  input),
  `--prefix-ssd off`, and the faults `RANK:prefix_ssd_restore_fail=1` and
  `RANK:prefix_ssd_restore_stall=MILLISECONDS` (qualification flag only). The
  launcher report keeps the `darkbloom-prefix-v1` and
  `darkbloom-prefix-ssd-v1` lines.

### Measured across the cable, 2026-10-11 (Mac A rank 0, Mac B = M5 Max rank 1)

27B (`Qwen3.8-27B-4bit-mtp`), cut 16, 8,192-token prompt, 64 greedy tokens,
binaries from `9da16036f`; each line is its own pair session (workers started
and stopped), SSD roots kept between sessions. Evidence folder
`ssd-20261011/cable`.

| Session | First token | Tokens | What the ranks did |
|---|---|---|---|
| Cold (pipeline) | 14.459 s | `f5c39b40…` (= cold reference) | prefilled, persisted one record per rank (rank 0 288 MB, rank 1 865 MB; 0.2 s behind serving) |
| Restart, same prompt | **0.322 s** | `f5c39b40…` identical | both restored frontier 8,191 from SSD (46 ms / 85 ms read), confirmed; a repeat in the same session was a resident hit (0.061 s) |
| Restart, second prompt (shares 7,680) | 0.134 s | `c0a6f86e…` = its cold reference | restored its own record from SSD |
| Restore fault on rank 1 | 14.357 s | identical | rank 0 restored, rank 1 failed: both prefilled from zero (records kept) |
| SIGTERM rank 1 halfway through its restore | (failed request) | | rank 0 ended by itself; no worker left, wired memory back on both; records unchanged |
| Next session | 0.312 s | identical | restored from SSD |
| Phase split + MTP cold / restart | 14.286 s / **0.446 s** | identical | own plan directory (mode is in the scope); opening it swept the pipeline plan on both ranks |
| Another cut (20), then the off switch | | | other plans swept on both ranks; off deleted every plan directory on both ranks |

Model-free and unit checks: the runtime's prefix suites (14 tests),
`ClusterInstalledSessionChecks` (durable owner key: file made once, kept by a
later owner, an unusable file left alone, the product key preferred when it
loads), qualification, diagnostics and console check runners.

Open: the product path (`darkbloom start` on the pair) has not been run with
the tier (harness ready; Mac B was being replaced when this was written); the
KEK-derived key needs the signed build to be exercised (unsigned builds use the
key file).

## Full caching on the cluster path (work/cluster-full-caching, 2026-10-12)

Built on integration round 3 with the SSD tier merged, against the owner's
oMLX caching as the reference (`omlx/cluster/prompt_snapshot_cache.py`,
`omlx/cache/paged_ssd_cache.py`, the teardown, reclaim and MTP-timeline
commits; the mechanism-by-mechanism map is in
`evidence/full-caching-20261012/STATUS.md`, "Architecture").

- The record format (`QwenStagePrefixDiskRecord`) gained an optional
  `history` section: the decoding rank's speculative head history at each
  kept frontier (three whole units: hidden `[1, f-1, H]`, tokens `[1, f-1]`,
  last `[1, 1, H]`), restored into `QwenStagePrefixState.speculativeHistory`,
  so a restore from the SSD drafts from the whole prompt as a resident hit
  does (PERF-BACKLOG 13; oMLX `51df0333`). Records without the section
  still restore (nil history).
- Teardown (`QwenStagePrefixDiskTier.close`) finishes queued records within
  its bound and extends the bound once, by itself, when a record completed
  since the close began (progress), never when the writer is stuck (oMLX
  `a58afee1`). `Statistics.closeExtended` / `closeDrained` report it.
- A disk restore this rank adopted but the peer could not confirm stays
  resident (within the budget) so the next offer is a memory hit instead of a
  second read and decryption (oMLX U#3327, `event=restore-kept`). Every
  promoted restore now charges its attention copy and history to the
  resident budget (`QwenStagePrefixState.sharedBytes`); before, only the
  recurrent bytes were counted.
- Only prompt frontiers (`1..<promptCount`) are offered or written: no
  drafted or generated timeline can reach a record (oMLX
  mtp-terminal-commit), asserted by tests.
- Settings: the pair reads the PRODUCT's caching surface
  (`ClusterPrefixCacheSettings.product`: `darkbloom cache set` directory and
  daily write cap, `DARKBLOOM_PREFIX_CACHE`, `DARKBLOOM_PREFIX_CACHE_DISK_GB`
  else half the free space, the 1,800 s TTL ceiling), installed once by
  `cluster worker-owner`; the rank's root is
  `<cache base>/darkbloom/cluster-prefix-v1`, beside the single-Mac `kv3`
  tier; the key derives from the same Secure Enclave-rooted KEK. The
  `DARKBLOOM_CLUSTER_PREFIX_*` variables remain diagnosis overrides.
  `darkbloom cache status` shows the cluster tier (plans, records, bytes;
  `--json` per plan and rank). `darkbloom cluster pair --forget` reclaims this
  Mac's records (never a plan a live rank holds). `ClusterCacheSettingsSync`
  is the versioned settings subset the leader sends members; its transport is
  the onboarding track's control channel.
- Sliding-window stages (Gemma 4, GPT-OSS) still refuse capture; the ring
  snapshot design (one window unit per kept frontier, as oMLX stores the full
  rotating state per boundary) is written up in the STATUS, not built.

## Not built

**Paged KV in the stages.** The product's `PagedKVBackend` implements the same
`CBv2KVBackend` protocol and its `PagedLayerCache` owns attention dispatch, so
the model forward would not change. What blocks a bounded adoption:

1. Ownership. `CBv2OwnedRequestState` creates a contiguous backend per request
   and validates and snapshots through `CBv2LayerCache` rows and position
   offsets (about fifteen sites in `State/`). A paged pool is
   construction-fixed (slabs committed at first admission; capacity updates
   are no-ops), so it must live with the loaded stage in the resident runtime,
   and the state layer must be rewritten against `PagedSequenceKV`.
2. Admission. The resident allowance (`QwenDenseStageLoadResources`,
   `QwenResidentRequestResources`, `QwenLongPrefillTensorBudget`) and the
   phase-split allowance charge contiguous per-request KV for the maximum
   length. Paged needs the pool in the load-time footprint and page
   reservations per request, including on the decoding rank that holds every
   layer.
3. Hand-off. Snapshots of paged storage are recyclable
   (`requiresMaterializedSnapshots`), and adoption takes a
   `CBv2PrefixReusePlan`; the phase-split receiver needs a `.direct` plan.
4. Numerics. Paged decode for these models runs the paged Metal kernel, not
   the contiguous attention, so both modes on both models need requalifying
   against the single-Mac product, and the staged reference needs the same
   backend to stay an oracle.

With one request at a time on the pair (FEATURE-PARITY row 9) paged KV brings
no throughput; its value comes with batching and page-shared prefixes.
