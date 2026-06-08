# SSD KV Cache — How It Works

How the Swift provider caches prefill KV, encrypts it at rest, and reloads
it — the as-built behavior. For the design rationale, threat model, and
phased plan see **[ssd-kv-cache-design.md](ssd-kv-cache-design.md)**; this
doc is the operator + engineer reference for what actually runs.

> **Status / safety gate.** The cache is **ON by default** (operator decision);
> opt out with `DARKBLOOM_PREFIX_CACHE=0`. It also requires the machine to
> persist a Secure-Enclave-wrapped key — if the SE/entitlement is missing it
> stays off rather than use an ephemeral key. It re-introduces a cross-tenant
> TTFT side-channel (TB-007) that encryption does NOT mitigate — untrusted
> multi-tenant deployments MUST opt out. See [Security model](#security-model).
> With the flag set to `0` the engine runs with `prefixCache: nil`: no cache, no
> files, today's exact behavior.

---

## 1. What it caches and why

Inference does two things per request: a **prefill** pass over the prompt
(builds the KV cache for every prompt token) then **decode** (one token at
a time). Prefill is the expensive part of time-to-first-token (TTFT) and is
*pure recomputation* of the same prompt. When many requests share a prefix
— a long system prompt, a few-shot preamble, a RAG context block — every
request re-pays that prefill from scratch.

The cache stores the KV tensors for shared prompt prefixes so a later
request with the same prefix **skips that prefill** and only prefills the
suffix it hasn't seen. It has two storage levels:

- **In-GPU block cache** — the engine's own `PrefixCache`: prompt KV sliced
  into fixed `blockSize`-token blocks, kept in GPU memory, content-addressed
  by a chain hash over the tokens. Survives eviction *within* a run.
- **Encrypted SSD tier** — when the GPU block cache evicts a block, instead
  of dropping it we encrypt it to disk (`*.darkbloom-kv`). It survives
  eviction *and* process restart, and is reloaded on the next matching
  request.

Plaintext KV never touches disk: it is AES-256-GCM-sealed in memory and the
ciphertext is what's written.

---

## 2. Tiers and what's wired

```
                request prompt tokens
                        │
              ┌─────────▼──────────┐
              │  Engine PrefixCache │   in-GPU blocks, blockSize=256,
              │   (hashIndex / LRU) │   blockSize=256, memory-bounded, chain-hashed
              └─────────┬──────────┘
                   miss │ evict
              ┌─────────▼──────────────────────┐
              │ EncryptedPrefixCachePersistence │  ← the WIRED SSD backend
              │  saveBlock / loadBlock (sync)   │
              └─────────┬──────────────────────┘
                        │ uses
       ┌────────────────┼───────────────────────┐
       ▼                ▼                         ▼
 KVCacheSerializer  EncryptedKVStore        KVCacheKEK
 ([KVCache]↔bytes)  (DBKV file format)      (SE-wrapped KEK, per-file DEK)
```

**Wired (behind the flag):** the engine `PrefixCache` + the
`EncryptedPrefixCachePersistence` SSD backend. This tier handles
**`KVCacheSimple` blocks only** (the engine's block cache is
KVCacheSimple-only). Pure-attention models benefit directly; models whose
attention is hybrid (sliding-window / recurrent layers — Gemma-4 MoE,
GPT-OSS-20B, Qwen3.5-class MoE) are not served by this tier because their
per-layer caches aren't all `KVCacheSimple`.

**Wired (behind the flag) for hybrid models:** the checkpoint-level
`PrefixCacheManager` + `PrefixCacheIndex` + `PrefixDigest` + `PrefixCacheRAM`.
This is an exact-checkpoint cache (hash the prompt at fixed lengths 256,
512, 1024, …) that supports both `KVCacheSimple` and `RotatingKVCache` via
`KVCacheSerializer`, so it serves the **hybrid sliding-window** models
(Gemma-4, GPT-OSS) the engine block tier excludes. `BatchScheduler`
constructs it for `.checkpoint`-strategy models; capture happens at
checkpoint boundaries during prefill, restore on a matching `submit`. It
shares the same on-disk format, crypto, and load-path guards as the block
tier. See **[ssd-kv-cache-hybrid-models.md](ssd-kv-cache-hybrid-models.md)**
for the full capture/restore design and verification.

The shared primitives on the live path are `EncryptedKVStore` +
`KVCacheSerializer` + `KVCacheKEK`. The engine tier reaches them via
`EncryptedPrefixCachePersistence` (pure-attention models); the checkpoint tier
via `PrefixCacheManager` + `PrefixCacheIndex` + `PrefixCacheRAM` (hybrid
sliding-window models). Both tiers are wired into `BatchScheduler` behind the
flag — which tier a model uses is decided by `PrefixCacheStrategy.classify`.

---

## 3. Enabling / disabling it

The prefix cache is **ON by default**. To disable it, opt out on the provider
process:

```bash
DARKBLOOM_PREFIX_CACHE=0                     # opt OUT (default = ON); also false/off/no
DARKBLOOM_PREFIX_CACHE_MAX_GB=8              # optional: in-GPU block-cache budget (default = 1/8 physical RAM)
DARKBLOOM_PREFIX_CACHE_DISK_GB=50            # optional: GLOBAL on-disk budget across ALL models. Unset / 0 / non-numeric = DERIVE min(10 GiB, 50% of free), re-evaluated each tick (NOT unlimited). For effectively-unbounded, set a very large explicit value.
DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS=0  # optional: 2nd-use admission threshold (default = 16384 for Gemma, 0 otherwise)
```

`MAX_GB` bounds the in-memory block cache (the number of GPU blocks is
derived from it + the model's per-token KV bytes, so a large model can't
silently retain hundreds of GB outside admission control). `DISK_GB`
bounds the encrypted SSD files **globally across all loaded models**
(value-based eviction — see [§11](#11-on-disk-layout)). `MIN_PERSIST_TOKENS`
gates SSD writes (checkpoints below this stay RAM-only until a 2nd use promotes
them — see [§4.2](#42-evict--encrypt-to-ssd)).

Wiring happens in `BatchScheduler.makeBatchedEngine` /
`makeEncryptedPrefixPersistenceIfEnabled`
(`provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift`). The
cache is constructed **unless** it's opted out, and otherwise **only if** the
remaining conditions hold; if not it stays `nil` (off) and the provider logs why:

1. `DARKBLOOM_PREFIX_CACHE` is NOT set to `0`/`false`/`off`/`no` (default = on).
2. The model architecture exposes `numLayers`, `kvHeads`, `headDim`.
3. A persistent KEK is available: a Secure-Enclave identity
   (`PersistentEnclaveKey.loadOrCreate`) + Keychain storage
   (`KeychainWrappedKEKStorage`). If the SE/entitlement is missing, the
   cache is **disabled rather than** falling back to an ephemeral key
   (which wouldn't survive restart and would silently break reuse).

When active you'll see, once per model load:

```
Prefix cache is ON (default; opt out with DARKBLOOM_PREFIX_CACHE=0) — TB-007: …
encrypted prefix cache active for <modelId> (bound to weightHash|modelId) at <dir>, disk budget <N> bytes (default = min(10 GiB, 50% of free volume space), GLOBAL across models)
prefix cache sized to <maxBlocks> blocks × 256 tok (~<kvBytesPerToken> B/tok)
```

---

## 4. The data path

### 4.1 Store (in-GPU)

After a request finishes, `PrefixCache.storePrefix` slices the completed KV
into `blockSize` (256)-token blocks, hashes each block with a chain hash
`computeBlockHash(parentHash, tokenIds, modelName)`, and parks complete
blocks in GPU `CacheBlock`s with `refCount = 0` (immediately evictable but
findable via `hashIndex`). Partial trailing blocks are not stored.

### 4.2 Evict → encrypt to SSD

When `allocateBlock()` needs a slot and none are free, it evicts the
least-recently-used evictable block. Before dropping the in-GPU data it
calls `persistence.saveBlock(blockHash, layerCaches)`:

`EncryptedPrefixCachePersistence.saveBlock`
(`provider-swift/Sources/ProviderCore/KVCache/EncryptedPrefixCachePersistence.swift`):

1. `KVCacheSerializer.serialize` → raw byte chunks + a layout descriptor.
2. Build `EncryptedKVStoreMetadata` (model hash, shape, `tokenCount`,
   `tokenPrefixHash = blockHash`, the layout JSON in `metaState`, per-chunk
   plaintext sizes).
3. `EncryptedKVStore.writeSync` → encrypt + atomically write
   `<blockHashHex>.darkbloom-kv` (see [§5](#5-on-disk-file-format)). Bodies
   larger than INT_MAX (2 GiB) are written in segments ≤1 GiB each (a single
   `write(2)` of ≥2 GiB fails EINVAL on Darwin), so large checkpoints
   (e.g. ~2.4 GB hybrid at 100k tokens) persist correctly.

**2nd-use admission (checkpoint tier only):** initial capture is RAM-only
(fast). An SSD file is written only on the **2nd use** (a re-lookup that
RAM-hits) of a prefix whose `tokenCount >= minPersistTokens` (env
`DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS`, default 16384 for Gemma, 0
otherwise). Stops write storms from one-off diverse prompts. The engine block
tier persists eagerly on eviction (no RAM-first admission).

Failures are best-effort: a lost block just means a future cold prefill.

### 4.3 Fetch → load from SSD

`PrefixCache.fetchPrefix` walks the prompt block by block:

- **In-GPU hit** (`hashIndex` has the block): use it, bump refcount.
- **Cold hit** (`hashIndex` miss, `persistence.loadBlock(hash)` returns KV):
  the block was evicted (or persisted in a prior run). If a GPU slot is
  free, reload it so later fetches hit in memory; **if the pool is
  saturated, the loaded block is still served for this request** (used,
  not resident).
- **Miss**: stop matching here.

The matched blocks are concatenated (axis 2) into one merged
`KVCacheSimple` per layer and returned with the **remaining** tokens. The
scheduler seeds the merged cache and prefills only `remaining`, so the
covered-token count must equal the *merged width* — including
cold-served-only blocks — or the suffix would overlap the seeded KV and
corrupt generation. (This is the length-accounting invariant fixed in
`PrefixCache.fetchPrefix`: `cachedTokens = matchedPerBlock.count * bs`.)

`loadBlock` is **synchronous** — it runs inside the engine step loop, so it
never hops actors: the KEK is unwrapped once at setup and held as a raw
`SymmetricKey`, and read/write use `EncryptedKVStore.readSync/writeSync`.

---

## 5. On-disk file format

One file per cached prefix: `<hashHex>.darkbloom-kv`. Defined in
`EncryptedKVStore.swift`.

```
offset  size  field
0       4     magic = "DBKV"
4       2     uint16 LE  format_version (= 1)
6       2     uint16 LE  flags (reserved, 0)
8       12    file_IV          random per file; folded into the HKDF info (not a salt)
20      4     uint32 LE  wrapped_DEK length N
24      N     wrapped_DEK      AES-256-GCM(KEK, DEK, AAD=metadata) = nonce‖ct‖tag
24+N    4     uint32 LE  metadata length M
28+N    M     metadata         JSON (canonical, sorted keys); plaintext; AAD for every chunk
28+N+M  4     uint32 LE  chunk_count
  per chunk:
        4     uint32 LE  ciphertext length (= plaintext + 16 tag)
        var   AES-256-GCM ct‖tag   (nonce HKDF-derived, not stored)
```

**Metadata (`EncryptedKVStoreMetadata`)** is the file's self-description and
the AAD for every chunk seal. Key fields: `modelHash`, `modelDtype`,
`modelArch`, `vocabSize`, `numLayers`, `kvHeads`, `headDim`, `tokenCount`,
`tokenPrefixHash` (identity of the prefix this file holds), `kvCacheClass`,
`metaState` (the serializer layout JSON), `chunkPlaintextSizes`,
`createdAt`, `expiresAt?`.

The metadata is **not encrypted** — a reader can inspect it (model, shape,
prefix hash) and decide whether to load the file *without* paying a KEK
unwrap. Confidentiality covers the KV tensors only. Because the metadata is
the GCM AAD, tampering with **any** field fails authentication on every
chunk. It's encoded with sorted keys + `withoutEscapingSlashes` so the AAD
bytes are byte-identical on write and read.

**Per-chunk nonces** are derived, not stored
(`EncryptedKVStore.deriveChunkNonce`), HKDF-Expand only (Extract skipped —
the DEK is already a uniform 256-bit key):

```
PRK  = DEK                                         (no salt)
info = "dbkv-chunk-v1" ‖ file_IV ‖ uint32_be(chunk_index)
L    = 12 bytes
```

`file_IV` is random per file, so even if DEK material ever repeated, two
files get distinct `info` → distinct nonces. Within a file, `chunk_index`
separates them.

**Atomic write** (`EncryptedKVStore.atomicWrite`): write to a UUID-suffixed
temp file, `fsync`, then rename into place — `moveItem` when the
destination is absent (the first-write case), `replaceItemAt` to swap an
existing file. Both are atomic within one filesystem; a crash leaves an
orphan temp or an absent file, never a torn final file. The directory entry
is then flushed (`F_FULLFSYNC`, best-effort).

---

## 6. Cryptography & keys

Envelope encryption — a long-lived **KEK** wraps a per-file **DEK**:

```
Secure Enclave identity (P-256, persistent, keychain-access-group bound)
        │ ECIES wrap/unwrap (SecureEnclaveKeyWrappingService)
        ▼
KEK  (random 256-bit, one per provider)  ──stored wrapped in Keychain──┐
        │ AES-256-GCM wrap, AAD = file metadata                        │ KeychainWrappedKEKStorage
        ▼                                                              │
DEK  (random 256-bit, one per file)  ── stored wrapped in file header ─┘
        │ HKDF-Expand → per-chunk nonce
        ▼
KV chunk ciphertext (AES-256-GCM, AAD = file metadata)
```

- **KEK** (`KVCacheKEK`): generated once, wrapped via the SE identity, and
  persisted in the Keychain. `loadOrCreate()` unwraps it once and holds it
  in the actor; subsequent calls are free. Lifetime = provider lifetime.
  `wipe()` deletes the wrapped KEK (rotation / tests) — note this makes all
  existing cache files unreadable; they're cleaned up by the eviction sweep.
- **DEK** (`KVCacheKEK.freshDEK`): a fresh random 256-bit key per file,
  wrapped under the KEK with the file metadata as AAD, stored in the header.
  Fresh per write ⇒ no GCM nonce reuse across files.
- **Why CryptoKit only:** all primitives are Apple CryptoKit
  (`AES.GCM`, `HKDF`, SE ECIES) — no custom crypto.

In tests the same interfaces are backed by in-memory implementations
(`InMemoryKeyWrappingService`, `InMemoryWrappedKEKStorage`) and a transient
SE key, so the crypto path is exercised without code signing.

---

## 7. Serialization (`KVCacheSerializer`)

Converts `[any KVCache]` (one cache per layer) ↔ encryptable byte chunks +
a `KVCacheLayout` (per-layer class name, `metaState`, and an array
descriptor `{shape, dtype}` per state array). The layout JSON rides inside
the file metadata (so it's AAD-bound).

- **Byte round-trip** uses `MLXArray.asData(access: .copy)` and
  `MLXArray(data:shape:dtype:)` — dtype-agnostic, so **bf16 round-trips
  exactly** (no float32 detour).
- **Supported types:** `KVCacheSimple` (`"KVCache"`) and `RotatingKVCache`
  (sliding-window). Reconstructed via each type's public `state`/`metaState`
  setters.
- **Rejected:** `MambaCache`/`ArraysCache` (recurrent state — no public
  reconstruction; would silently produce garbage), `ChunkedKVCache`,
  `QuantizedKVCache`, `CacheList`. `serialize` throws on any unsupported
  layer.

Consequence: hybrid models get the in-RAM `copy()` tier only (no SSD) until
upstream exposes a public recurrent-state reconstruction. The wired engine
tier is narrower still — `KVCacheSimple` only.

---

## 8. The load-path verification ladder

This is the security-critical part. A `*.darkbloom-kv` file authenticates
**under its own metadata** (the AAD is its own metadata), so a wrong file
still decrypts cleanly. The load path must therefore independently verify
the file is the **right** one for *this* request and *this* model — and any
failure must degrade to a **cold miss** (re-prefill), never a crash and
never wrong KV. Both load paths (`EncryptedPrefixCachePersistence.loadBlock`
and `PrefixCacheManager.loadFromSSD`) apply this ladder:

1. **Path is derived, not trusted.** The file path is reconstructed from
   trusted values — content-addressed `<blockHash>.darkbloom-kv` (engine
   tier) or `<modelDir>/<digest>.darkbloom-kv` from the binding + index key
   (checkpoint tier). The unauthenticated index's stored `relativePath` is
   **ignored**, so a tampered index can't traverse out of the cache dir.
2. **Metadata read without decrypt** (`readMetadataOnly`). Unreadable →
   drop + cold miss.
3. **Model binding (MB-1):** `meta.modelHash == binding.modelHash`. A
   wrong-model file (e.g. a 12-char model-dir-prefix collision) is rejected.
4. **Shape integers:** `meta.numLayers / kvHeads / headDim == binding`.
5. **Prefix identity:** `meta.tokenPrefixHash ==` the requested block hash
   (engine) / index digest (checkpoint). Stops a renamed/swapped same-model
   file from serving a *different* prompt's KV.
6. **Decrypt** (`readSync`/`read`): unwrap the DEK (AAD = metadata), derive
   each chunk nonce, AES-GCM-open (AAD = metadata). Any tamper → auth
   failure → cold miss.
7. **Tensor shape binding** (`KVCacheSerializer.validateLayout`): every KV
   array is rank-4 with `shape[1] == kvHeads` and `shape[3] == headDim`.
   The metadata integers (step 4) are a self-asserted claim; this binds the
   actual tensors that seed attention to the live model.
8. **Decode safety** (`KVCacheSerializer.deserialize` / `reconstruct`),
   guarding the engine's `fatalError`-ing setters — these would be
   *uncatchable* and crash the provider, so each is pre-checked and turned
   into a throw → cold miss:
   - per-array byte length `== shape.product × dtype.size`
     (overflow-safe; rejects negative/overflowing dims) — else the MLXArray
     init precondition would trap;
   - per-layer state-array count ∈ {0, 2} — else the `state` setter traps;
   - `metaState` well-formed for its type (`KVCacheSimple` requires `[""]`;
     `RotatingKVCache` requires 5 integer fields, `maxSize != "None"`) —
     else the `metaState` setter traps.

The invariant: **a malformed, stale, foreign, or tampered file is always a
recoverable cold miss** — never wrong KV served, never a process crash.

---

## 9. Exact-checkpoint matching (checkpoint tier)

The `PrefixCacheManager` tier (wired into `BatchScheduler` for hybrid
sliding-window models — Gemma-4, GPT-OSS — when the flag is on) keys prefixes
by **exact checkpoint** rather than longest-common-prefix. `PrefixDigest` hashes the
prompt's first `c` tokens at fixed boundaries (256, 512, 1024, 2048, 4096,
8192) in a single rolling-SHA pass, so two prompts sharing a system prompt
produce identical digests at every checkpoint inside the shared region.
`PrefixCacheIndex.findLongestCheckpoint` returns the entry for the **longest
present checkpoint** for that model — an O(checkpoints) lookup, no full
prefix scan.

The index (`PrefixCacheIndex`) is JSON, loaded into RAM at startup, mutated
in memory, written back atomically. It maps `(modelHash, digestHex)` → file
+ token count + LRU metadata, partitioned by `modelHash` (MB-1). It is
**not** cryptographically authenticated — its integrity is backstopped by
the load-path ladder (§8): the path is derived from the digest (not the
stored `relativePath`), and the served file's `tokenPrefixHash` must equal
the index digest. A corrupt index is treated as empty and rebuilt from the
self-describing files.

---

## 10. Failure modes

Everything fails closed to a cold prefill:

| Situation | Result |
|---|---|
| Flag unset / SE unavailable / incomplete arch | cache off (`prefixCache: nil`) |
| File missing | cold miss |
| Metadata unreadable / wrong model / wrong shape | drop entry, cold miss |
| Wrong prefix hash (rename/swap/stale index) | refuse, cold miss |
| GCM auth failure (tamper) | cold miss |
| Layout shape ≠ model, bad byte length, bad array count, bad metaState | throw → cold miss |
| Block pool saturated on a cold hit | block served for this request only |
| Write failure mid-flush | best-effort; temp cleaned up, no partial promoted |
| In-memory budget can't fit one block | cache disabled for that model (logged) |
| On-disk files exceed `DISK_GB` | lowest benefit-per-byte entries evicted (cross-model) to fit |
| Weights change under the same model id | MB-1 rejects + deletes stale-weight files on access; rest aged out by the sweep |
| A single file larger than the global disk budget | write skipped (no churn) |
| Bodies >2 GiB (INT_MAX) | written in ≤1 GiB segments (Darwin `write(2)` limit) |

No path serves KV for the wrong prefix/model, and no malformed file crashes
the provider.

---

## 11. Disk budget (global accountant)

**Phase 3 (as-built):** the disk budget is **process-wide and global** across
all loaded models, enforced by `GlobalDiskAccountant`
(`provider-swift/Sources/ProviderCore/KVCache/GlobalDiskAccountant.swift`).
When `DARKBLOOM_PREFIX_CACHE_DISK_GB` is set (>0), it caps the ENTIRE
`darkbloom/kv/` tree (all models combined). When unset (or 0), the default is
`min(10 GiB, 50% of free disk)` recomputed live every 30 seconds.

**Cross-model value-based eviction:** when the global total exceeds the
ceiling, the accountant merges all models' value summaries (owned + unowned
dirs), sorts by **benefit-per-byte score** (ascending), and evicts the
lowest-score entries across the fleet until back under budget. Score =
`((hitCount+1) * tokenCount * prefillCostPerToken / max(1, fileBytes)) *
recency`, where recency uses hyperbolic decay (halfLife = 24h default). For
OWNED models (a live `PrefixCacheManager` actor), the accountant **signals**
the owner to evict (the owner runs the deletion on its own executor —
actor-isolated, no cross-actor race). For UNOWNED dirs (no live actor — a
retired/unloaded model), the accountant directly deletes files and rmdirs when
empty.

**Retired-model reclaim:** directories from unloaded models are not deleted on
teardown; they persist so a restart can reuse their files. Under disk pressure
the periodic tick (every 30s) scans the `darkbloom/kv/` tree, sums unowned
dirs' bytes, builds degraded value summaries (mtime-LRU for files not in any
live index), and reclaims them via the cross-model eviction. This preserves
restart reuse while avoiding orphan leaks.

**Cross-actor safety property:** the accountant NEVER directly deletes a file
owned by a live model (registered manager) — it signals the owner, which
evicts on its own executor (auto-serialized vs flush/lookup/load). Direct
filesystem deletion happens ONLY for UNOWNED dirs (no live actor → no race).
See issue #266.

---

## 12. On-disk layout

```
~/Library/Caches/darkbloom/kv/
└── <modelKey>/                         # engine tier: sha256(modelId)[:12]
    ├── <blockHashHex>.darkbloom-kv     # one file per evicted block
    └── …
```

`modelKey` is derived from the **model id** (stable across weight changes),
so a re-download under the same id reuses the directory rather than
orphaning it. The MB-1 **binding** (the file's `metadata.modelHash`) is
keyed by the **weight identity** (`weightHash` when the catalog provides it,
else the model id): a stale-weight file is rejected *and deleted* by
`loadBlock` on access, and any not-yet-accessed stale file is aged out by
the disk sweep — invalidation on weight change without leaking directories.
A genuine model *switch* uses a different `sha256(modelId)` directory. The
KEK lives in the Keychain, not on the cache disk.

The **global** disk budget (see [§11](#11-disk-budget-global-accountant))
defaults to `min(10 GiB, 50% of free space)` when
`DARKBLOOM_PREFIX_CACHE_DISK_GB` is unset, recomputed live. When set (>0), it
caps the entire `darkbloom/kv/` tree across all models. Eviction is
cross-model value-based: lowest benefit-per-byte score evicts first,
regardless of which model owns the file. A file whose own size exceeds the
global budget is skipped entirely (no write-then-delete churn). Set the env
var to a positive value to raise/lower the cap; unset / 0 / non-numeric
derives `min(10 GiB, 50% of free)` (re-evaluated each tick) — NOT unlimited.
For effectively-unbounded, set a very large explicit value.

Both tiers enforce this budget: the engine block tier
(`EncryptedPrefixCachePersistence`) and the checkpoint tier
(`PrefixCacheManager`) notify the accountant after each byte-changing op
(flush, persist, eviction). The accountant signals the owning model to evict
when the global total exceeds the ceiling.

**Crash consistency.** The checkpoint index save is *coalesced* (every N
writes, not every flush) to keep the O(N) re-encode off the hot lookup
path. To stay crash-safe, the manager **reconciles index ↔ on-disk files
once at load** (`reconcileWithDisk`): files present but unindexed — orphans
from a crash inside the coalescing window, or a corrupt/missing
`index.json` — are re-indexed from their (unauthenticated) metadata header
after validating model + prefix-hash binding, so they count toward the disk
budget and are reusable instead of leaking; index entries whose file
vanished are dropped; foreign/mislabeled files are deleted. So coalescing
keeps its perf win without leaking disk or losing cache across restart. A
graceful unload also `flushIndexNow()`s before dropping the manager.

**Bounding is GLOBAL (Phase 3, as-built), not per-model.** One process-wide
ceiling shared across all loaded models; the accountant scans the entire
`darkbloom/kv/` tree (all model dirs + unowned dirs). The default
`min(10 GiB, 50% of free)` is recomputed every 30s, so it shrinks if the
volume fills from other writers. Cross-model value-based eviction ensures the
lowest-value KV (across the fleet) is dropped first, so a high-churn
many-model deployment doesn't over-commit. Retired-model dirs (unowned) are
reclaimed under pressure (not on unload), preserving restart reuse.

> **Rollout guidance.** Out of the box (default-on, nothing else set) the
> GLOBAL default is `min(10 GiB, 50% of free)` — safe for
> multi-model deployments; the accountant cross-model-evicts to stay under
> one ceiling. Raise `DARKBLOOM_PREFIX_CACHE_DISK_GB` explicitly when you have
> headroom. The global accountant resolves issue
> [#266](https://github.com/Layr-Labs/d-inference/issues/266) (the per-model
> limitation is retired).

**Known limitation (low):** a model directory is keyed by `sha256(modelId)`
and is *not* deleted when that model is retired/unloaded, so directories
from no-longer-served models linger (each still bounded by its own budget,
but the parent `darkbloom/kv/` tree has no cross-model GC). Reclaim by
deleting `darkbloom/kv` or stale `<modelKey>` subdirs out of band. Stale
atomic-write temp files (`*.tmp-*`) from a process kill are swept on the
next cache setup for that model.

To clear the cache: delete the `darkbloom/kv` directory. To invalidate all
files cryptographically: rotate/`wipe()` the KEK (existing files become
undecryptable and are swept).

---

## 13. Security model (TB-007)

This cache adds **encryption-at-rest** (disk-theft / local-attacker
defense). It does **not** close the in-process **cross-tenant** channel:
the provider can't see tenant identity, so a shared prefix block is shared
across consumers, and the TTFT difference between a cache hit and miss is a
timing oracle (a tenant who already knows the exact prompt tokens can detect
whether someone else cached them). The cache is **on by default** per an
explicit operator decision accepting this channel for trusted / single-tenant
deployments; **untrusted multi-tenant deployments MUST opt out** with
`DARKBLOOM_PREFIX_CACHE=0` (⇒ no cache ⇒ no exposure). Encryption-at-rest does
not change this. See the design doc's threat model for the full TB-007 analysis.

**At-rest scope — plaintext metadata is a known-prefix oracle for a disk
observer.** Encryption-at-rest covers the **KV tensors only**. The file header
metadata is plaintext (it's the GCM AAD, so it's authenticated but not
confidential): it carries `tokenCount`, the **stable prefix hash**
(`tokenPrefixHash` = SHA-256 over the prefix token IDs), the model-binding
fields (`modelHash`, `modelArch`, layer/head/dim shape), `createdAt`/`expiresAt`,
and the chunk layout. Because the prefix hash is a deterministic function of the
token IDs, an attacker with **read access to the cache directory** (not a tenant
— a disk/filesystem observer) can take a *guessed* prefix, compute its hash, and
test for equality against the on-disk filenames/metadata to **confirm whether a
known prompt prefix was cached** — and learn its token count and model. This is
a confirmation/equality oracle on guessable prefixes, not plaintext recovery (the
KV bytes stay encrypted). It is in-scope-accepted for the disk-theft threat model
(an attacker who can read the dir already defeats nothing of the KV confidentiality
guarantee) but is called out here so operators don't assume the filenames/metadata
are private. Mitigation if ever needed: salt/HMAC the on-disk prefix hash with a
per-install secret so it isn't directly recomputable from guessed tokens.

Model binding uses the **weight hash** (`ModelInfo.weightHash`) when the
catalog provides it, falling back to the `modelId` otherwise. The on-disk
directory stays keyed by the model id (so re-downloads don't orphan
directories); the weight hash goes into the file's MB-1 binding, so a
re-download under the same id with different weights makes every stale file
fail MB-1 — rejected and deleted on access, the rest aged out by the sweep.
When no weight hash is available the binding degrades to the model id; the
tensor-shape guard (§8) still catches shape-changing weight swaps in that
case.

---

## 14. Code & test map

| Concern | File |
|---|---|
| File format / crypto seal | `provider-swift/Sources/ProviderCore/KVCache/EncryptedKVStore.swift` |
| KEK envelope | `KVCacheKEK.swift`, `KeyWrappingService.swift`, `SecureEnclaveKeyWrappingService.swift`, `WrappedKEKStorage.swift` |
| `[KVCache]` ↔ bytes | `KVCacheSerializer.swift` |
| Wired SSD backend (engine tier) | `EncryptedPrefixCachePersistence.swift` |
| Checkpoint tier (wired) | `PrefixCacheManager.swift`, `PrefixCacheIndex.swift`, `PrefixDigest.swift`, `PrefixCacheRAM.swift`, `PrefixCachePastWindow.swift` |
| Global disk accountant (Phase 3) | `GlobalDiskAccountant.swift` |
| Flag wiring + budget resolution | `Inference/BatchScheduler.swift` (`makePrefixCacheBackingIfEnabled`, `resolveDiskBudget`, `prefixCacheMinPersistTokens`) |
| Engine block cache + persistence hook | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatching/PrefixCache.swift` |
| Tests | `provider-swift/Tests/ProviderCoreTests/KVCache/*`, `libs/mlx-swift-lm/Tests/MLXLMTests/CBPrefixCacheTests.swift` |

Design rationale, threat model, phased plan, open questions:
**[ssd-kv-cache-design.md](ssd-kv-cache-design.md)**. Model-binding diagram:
[`ssd-kv-cache-model-binding.png`](ssd-kv-cache-model-binding.png).
