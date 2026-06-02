# SSD KV Cache — How It Works

How the Swift provider caches prefill KV, encrypts it at rest, and reloads
it — the as-built behavior. For the design rationale, threat model, and
phased plan see **[ssd-kv-cache-design.md](ssd-kv-cache-design.md)**; this
doc is the operator + engineer reference for what actually runs.

> **Status / safety gate.** The cache is **OFF by default**. It is enabled
> only when the operator sets `DARKBLOOM_PREFIX_CACHE=1` AND the machine
> can persist a Secure-Enclave-wrapped key. Enabling it re-introduces a
> cross-tenant TTFT side-channel (TB-007) — see [Security model](#security-model).
> With the flag unset the engine runs with `prefixCache: nil`: no cache, no
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

The pieces actually on the live path are `EncryptedKVStore` +
`KVCacheSerializer` + `KVCacheKEK` + `EncryptedPrefixCachePersistence`.

---

## 3. Enabling it

Set the env var on the provider process:

```bash
DARKBLOOM_PREFIX_CACHE=1              # enable (default off); or =true
DARKBLOOM_PREFIX_CACHE_MAX_GB=8       # optional: in-GPU block-cache budget (default = 1/8 physical RAM)
DARKBLOOM_PREFIX_CACHE_DISK_GB=10     # optional: on-disk budget per model (default = 50% of free volume space; 0 = unlimited)
```

`MAX_GB` bounds the in-memory block cache (the number of GPU blocks is
derived from it + the model's per-token KV bytes, so a large model can't
silently retain hundreds of GB outside admission control). `DISK_GB`
bounds the encrypted SSD files per model (LRU sweep — see [§11](#11-on-disk-layout)).

Wiring happens in `BatchScheduler.makeBatchedEngine` /
`makeEncryptedPrefixPersistenceIfEnabled`
(`provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift`). The
cache is constructed **only if all** of these hold; otherwise it stays
`nil` (off) and the provider logs why:

1. `DARKBLOOM_PREFIX_CACHE` is `1`/`true`.
2. The model architecture exposes `numLayers`, `kvHeads`, `headDim`.
3. A persistent KEK is available: a Secure-Enclave identity
   (`PersistentEnclaveKey.loadOrCreate`) + Keychain storage
   (`KeychainWrappedKEKStorage`). If the SE/entitlement is missing, the
   cache is **disabled rather than** falling back to an ephemeral key
   (which wouldn't survive restart and would silently break reuse).

When active you'll see, once per model load:

```
DARKBLOOM_PREFIX_CACHE is ON — engine prefix cache enabled (TB-007: …)
encrypted prefix cache active for <modelId> (bound to weightHash|modelId) at <dir>, disk budget <N> bytes (default = 50% of free volume space)
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
   `<blockHashHex>.darkbloom-kv` (see [§5](#5-on-disk-file-format)).

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

The (unwired) `PrefixCacheManager` tier keys prefixes by **exact
checkpoint** rather than longest-common-prefix. `PrefixDigest` hashes the
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
| On-disk files exceed `DISK_GB` | oldest `.darkbloom-kv` evicted (LRU) to fit |
| Weights change under the same model id | MB-1 rejects + deletes stale-weight files on access; rest aged out by the sweep |
| A single block larger than the disk budget | write skipped (no churn) |

No path serves KV for the wrong prefix/model, and no malformed file crashes
the provider.

---

## 11. On-disk layout

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

The per-model directory is bounded by `DARKBLOOM_PREFIX_CACHE_DISK_GB`,
defaulting to **50% of the free space on the cache volume** (measured live
at model load, via `volumeAvailableCapacityForImportantUsage`): when a save
pushes the directory over budget, the oldest `.darkbloom-kv` files are
evicted (LRU by mtime), amortized so the directory scan doesn't run on
every block. A (near-)full disk yields a tiny budget — and a block whose
own size exceeds the budget is skipped entirely (no write-then-delete
churn). Set the env var explicitly to override (0 = unlimited); if free
space can't be read it falls back to 10 GB.

Both tiers enforce this budget: the engine block tier
(`EncryptedPrefixCachePersistence`) sweeps on save, and the checkpoint tier
(`PrefixCacheManager.flushToSSD`) evicts least-recently-hit checkpoints
(file + index entry together) after each flush — so the per-model KV
directory **and** its `index.json` are both bounded under sustained
diverse-prompt traffic.

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

**Bounding is per-model, not global, and measured once at load.** Each
model directory gets its own 50%-of-free budget snapshotted at its load
time; the sweep only scans its own directory. So with several distinct
models cached, aggregate `darkbloom/kv` usage can exceed 50% of the
original free space, and a budget doesn't shrink if the volume later fills
from other writers (it's re-measured on the next model load). For a hard
global cap, set `DARKBLOOM_PREFIX_CACHE_DISK_GB` to an explicit per-model
value sized for the number of models served.

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

## 12. Security model (TB-007)

This cache adds **encryption-at-rest** (disk-theft / local-attacker
defense). It does **not** close the in-process **cross-tenant** channel:
the provider can't see tenant identity, so a shared prefix block is shared
across consumers, and the TTFT difference between a cache hit and miss is a
timing oracle (a tenant who already knows the exact prompt tokens can detect
whether someone else cached them). That's why the cache is **default-off**,
opt-in via `DARKBLOOM_PREFIX_CACHE`, and ships only with an explicit
operator threat-model sign-off. Flag off ⇒ no cache ⇒ no exposure. See the
design doc's threat model for the full TB-007 analysis.

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

## 13. Code & test map

| Concern | File |
|---|---|
| File format / crypto seal | `provider-swift/Sources/ProviderCore/KVCache/EncryptedKVStore.swift` |
| KEK envelope | `KVCacheKEK.swift`, `KeyWrappingService.swift`, `SecureEnclaveKeyWrappingService.swift`, `WrappedKEKStorage.swift` |
| `[KVCache]` ↔ bytes | `KVCacheSerializer.swift` |
| Wired SSD backend | `EncryptedPrefixCachePersistence.swift` |
| Checkpoint tier (unwired) | `PrefixCacheManager.swift`, `PrefixCacheIndex.swift`, `PrefixDigest.swift`, `PrefixCacheRAM.swift` |
| Flag wiring | `Inference/BatchScheduler.swift` (`makeEncryptedPrefixPersistenceIfEnabled`) |
| Engine block cache + persistence hook | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatching/PrefixCache.swift` |
| Tests | `provider-swift/Tests/ProviderCoreTests/KVCache/*`, `libs/mlx-swift-lm/Tests/MLXLMTests/CBPrefixCacheTests.swift` |

Design rationale, threat model, phased plan, open questions:
**[ssd-kv-cache-design.md](ssd-kv-cache-design.md)**. Model-binding diagram:
`ssd-kv-cache-model-binding.svg`.
