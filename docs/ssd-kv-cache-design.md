# SSD KV Cache — Design Doc

> **Looking for how it actually works / loads?** See the as-built reference:
> **[ssd-kv-cache.md](ssd-kv-cache.md)**. This doc is the design rationale,
> threat model, and phased plan.

> Status: **P0 landed (crypto primitives) + cacheability VERIFIED.**
> Open questions are marked `[Q1]`, `[Q2]`, … and collected at the end.
>
> Branch: `feat/ssd-kv-cache` off `master`.
> Done: P0 `EncryptedKVStore` + KEK/DEK envelope encryption (committed);
> cross-model cacheability + rotating-cache restore correctness verified
> empirically (§4.4, §4.5; tests `RotatingKVCacheRestoreTests`,
> `BatchRotatingExtractRoundtripTests`).
> Pending: P1–P6 (RAM tier, index, BatchScheduler integration + MB-1
> model-binding guard, flush triggers, perf, telemetry).

## 1. Goal

Add a persistent, encrypted, on-disk tier for the model's KV cache so that
darkbloom can:

1. **Skip prefill on repeat prefixes** (system prompts, RAG context). The
   primary TTFT win.
2. **Survive process restart / model unload** without losing the most
   expensive precomputed state.

Both use the same on-disk format and crypto layer; they differ only in
*when* writes happen and *what* is written.

## 2. Non-goals (first cut)

- **Cross-machine cache sharing.** Each provider owns its own cache.
  Coordinator never sees plaintext (matches existing E2E invariant) or
  ciphertext.
- **TP/PP cluster KV.** Cluster KV is sharded per rank and synchronized
  via jaccl allreduce; persistence has fundamentally different
  consistency requirements. Single-rank only for v1. `[Q1]`
- **Live-request offload to SSD under pressure.** That's an eviction
  policy we may add later; v1 only saves *idle* state.
- **Cross-model cache reuse.** Cache files are bound to a specific
  `model_hash`. Switching models invalidates the cache for that model
  (it stays on disk for the next time that model loads).
- **Arbitrary longest-prefix match (was O2).** Dropped for the hybrid/
  sliding/recurrent models we actually serve (Qwen3.5/Next, Gemma-4,
  GPT-OSS). Their recurrent and sliding layers cannot be sliced to a
  shorter prefix, so reuse is **exact-checkpoint only** (see §4.4). Pure-
  attention models could support it, but we don't special-case them in
  v1 — one matching policy across all models.
- **Unsupported cache architectures.** Models whose `newCache()` yields
  `ChunkedKVCache`, `QuantizedKVCache`, `CacheList`, or a custom pooling
  cache (DeepseekV4) are gated out at load time and run cold. Only
  `KVCacheSimple` / `RotatingKVCache` / `MambaCache` (and their batched
  forms) are supported in v1.

## 3. Threat model

| Adversary | In scope? | Notes |
|-----------|-----------|-------|
| Cold-boot disk theft / forensics | ✅ | Primary motivation. KV is prompt-correlated, leaks the input distribution and (with effort) reconstructable approximations of plaintext context. |
| Backup snapshots (Time Machine, etc.) including the cache | ✅ | Same as disk theft. |
| Another process on the same Mac (no SIP bypass) | ✅ | SIP + hardened runtime + Keychain ACLs together gate access. KEK material never leaves the Secure Enclave. |
| The darkbloom provider process itself | ❌ | Already trusted with plaintext during inference. |
| Compromised root (post-exploit) | ⚠️ partial | An attacker who gets the persistent SE identity working as them can decrypt. We don't claim defense against full SE compromise. |
| Network adversary | ❌ | Cache never leaves the machine. |

**Confidentiality** is the hard requirement. **Integrity** is also a
hard requirement — silently loading a tampered KV would corrupt the
model's outputs in ways that look like a "model bug" rather than an
attack, so authentication via AES-GCM tag is non-negotiable.

## 4. Architecture overview

### 4.1 Three-tier hierarchy

```
                                            ┌────────────────────────┐
   Active in-flight request KVs       VRAM  │ BatchKVCache (existing)│
                                            └─────────┬──────────────┘
                                                      │ (eviction on
                                                      │  request done)
                                                      ▼
                                            ┌────────────────────────┐
   Recently-finished prefix KVs       RAM   │ PrefixCacheRAM (LRU)   │
   held as decrypted MLXArray              │  decrypted, in-process │
                                            └─────────┬──────────────┘
                                                      │ (eviction on
                                                      │  memory pressure
                                                      │  / idle offload)
                                                      ▼
                                            ┌────────────────────────┐
   Cold prefix KVs on disk            SSD   │ EncryptedKVStore       │
   AES-256-GCM, per-file DEK,              │  ~/.cache/darkbloom/kv │
   DEK wrapped by SE-KEK in Keychain       └────────────────────────┘
```

A request matches its longest shared prefix across all three tiers, in
order. The matched tokens are skipped during prefill.

### 4.2 Per-request flow (TTFT-optimized)

```
                       HTTP request arrives
                              │
       ┌──────────────────────┼──────────────────────┐
       │ (sequential)         │ (parallel with the   │
       │                      │  three lookups below)│
       ▼                      ▼                      │
  parse JSON           compute prefix digests        │
       │              for [first 256, 1k, 4k]        │
       ▼              prompt tokens (HKDF rolling     │
  apply chat          hash so longer prefix is        │
  template →          a continuation of shorter)     │
  token IDs                                          │
       │                                             │
       ▼                                             │
  ┌────────────────────────────────────────┐         │
  │ Tier check (EXACT-CHECKPOINT match;     │ ◄───────┘
  │  digest must equal a cached checkpoint): │
  │   1. PrefixCacheRAM  (decrypted, LRU)  │
  │   2. EncryptedKVStore (decrypt → RAM)  │
  │      └ MB-1 guard: meta.modelHash == loaded │
  │   3. miss → empty cache, full prefill  │
  └─────────────────┬──────────────────────┘
                    │ matched checkpoint length = L (0 on miss)
                    ▼
         Prefill tokens [L .. end]           ◄── TTFT saving
                    │
                    ▼
            Emit first token
                    │
                    ▼
            Decode loop (existing)
```

Tokenization and digest-compute proceed in parallel. SSD read +
decrypt is started speculatively as soon as the first 256-token digest
is available; if the request's actual prefix turns out shorter, we
discard the speculative load.

### 4.3 Write paths

| Trigger | Source tier | Destination | Notes |
|---------|-------------|-------------|-------|
| Request finishes, prefix is "common-looking" | VRAM → RAM | RAM tier promotes to SSD if RAM tier evicts | Heuristic: prompt ≥ N tokens AND not already in RAM |
| Idle-monitor unload (existing path) | RAM → SSD | flush RAM tier for that model before VRAM unload | Async; doesn't block the unload |
| Graceful shutdown (SIGTERM) | RAM → SSD | flush ALL models' RAM tiers | Bounded by a watchdog timer; partial flush is acceptable |
| Model swap (coordinator `load_model`) | RAM → SSD | flush the outgoing model's RAM tier | Same as idle unload |
| Crash / SIGKILL | — | — | SSD tier from prior writes survives. RAM tier lost. |

### 4.4 What gets cached — and the EXACT-CHECKPOINT model

> This section was rewritten after verifying the real cache types
> across the model zoo (see §4.5). The earlier draft assumed "slice
> the first N columns" and arbitrary longest-prefix match; both are
> wrong for the hybrid/sliding/recurrent architectures we serve.

**What:** the per-layer `[KVCache]` for a prefix, obtained by **extracting
one batch row** from the live continuous-batching caches — NOT by naive
tensor slicing. darkbloom runs `BatchKVCache` / `BatchRotatingKVCache`
/ batched `MambaCache` (one row per concurrent request); the prefix
snapshot for request *r* is `cache.extractBatched(r)`
(`BatchKVCache.swift`), which returns a standalone single-stream cache
(`KVCacheSimple` / `RotatingKVCache` / `MambaCache`) with its `state`
arrays **and** `metaState` strings populated. Those single-stream types
are exactly what upstream `savePromptCache`/`loadPromptCache` round-trips,
so we serialize the extracted row, not the batched cache.

**The cache tensors are 4-D**, `[B, kvHeads, seq, headDim]` per layer
(K and V separately). A prefix is a slice along **axis 2** (the
sequence axis), per layer × 2 — never "columns" of a matrix.

**EXACT-CHECKPOINT, not arbitrary longest-prefix.** A "prefix" here is
a contiguous run of token IDs from index 0, captured at a **fixed
checkpoint boundary** (e.g. the end of a system prompt). A cached entry
is reusable only when the incoming prompt's first *N* tokens are
**byte-identical** to that checkpoint. We do NOT support truncating a
cached length-*N* prefix to serve a shorter length-*M* prefix. Why this
is forced by the architectures (§4.5):

- **Recurrent layers (Mamba / GatedDeltaNet — e.g. Qwen3.5/Next):** the
  state after *N* tokens is a fixed-size *summary* `(conv_state,
  ssm_state)`, not per-token KV. It can be restored to resume at
  exactly *N* (verified sound), but it **cannot be sliced** to derive
  the state at *M < N* — the recurrence is non-invertible.
- **Sliding-window layers (Gemma-4, GPT-OSS):** the rotating buffer
  holds only the last *W* tokens; its circular/linear layout depends on
  the exact prefix length. Restore at the exact checkpoint is verified
  sound; arbitrary truncation is not.
- **Full-attention layers:** these *could* support longest-prefix slice,
  but a hybrid model is only as flexible as its least-flexible layer, so
  the whole model is exact-checkpoint.

This narrows the TTFT win (no arbitrary-prefix reuse) but still covers
the dominant case: a shared system prompt is a fixed exact prefix every
request replays.

**MANDATORY metaState-sync invariant (MS-1).** When we serialize an
extracted cache we MUST persist its `metaState` **in sync with** its
`state`, and restore both together. For `RotatingKVCache`, `metaState`
carries `[keep, maxCacheSize, step, offset, idx]`; `idx` is the
circular write-cursor that `temporalOrder()` depends on. Restoring
`state` without `metaState` leaves `idx`/`offset` at 0 and **silently
scrambles token order** on the next multi-token update. P0's
`EncryptedKVStoreMetadata` already has a `metaState: [String]` field —
the requirement is "never drop it." This is regression-guarded by
`omittingMetaStateOnRestoreCorruptsOrder` (which proves the corruption
is real) alongside the positive round-trip tests.

**Verified, not asserted.** The snapshot → restore → resume correctness
for the sliding-window path is proven empirically in
`RotatingKVCacheRestoreTests` (single-stream, incl. the wrapped
circular-buffer case) and `BatchRotatingExtractRoundtripTests` (the
`extractBatched(row)` path our design uses). Both match a never-reset
reference byte-for-byte.

### 4.5 Verified per-model cacheability

Cache type is determined by **attention architecture per layer**, which
must be detected at **load time** (inspect what `newCache()` returns) —
never hardcoded to a model name. MoE is irrelevant: it only changes the
FFN/expert routing, never the KV path.

| Model (served) | Per-layer caches | Prefix cache | Notes |
|---|---|---|---|
| Llama, Qwen2/3, Phi, Mistral, GLM4, Cohere (pure attention) | all `KVCacheSimple` | ✅ exact-checkpoint (could do longest-prefix) | simplest case |
| **Qwen3.5 MoE / Qwen3-Next** (hybrid) | `MambaCache` (3 of 4 layers) + `KVCacheSimple` | ✅ exact-checkpoint | recurrent state restorable at exact boundary; not sliceable. `fullAttentionInterval` default 4 |
| **Gemma-4 26B-A4B MoE** (sliding hybrid) | `RotatingKVCache` (w=512, 28/35) + `KVCacheSimple` (7/35) | ✅ exact-checkpoint | only **15 non-shared** caches to snapshot — 20 layers KV-share via forward-time indirection, reconstructed automatically |
| **GPT-OSS-20B MoE** (sliding hybrid) | `RotatingKVCache` (w=128, 18/36) + `KVCacheSimple` (18/36) | ✅ exact-checkpoint | attention sinks are **learned per-head weights, not KV state** — no snapshot impact |
| Qwen3.6 / 3.7 | not in tree yet | likely exact-checkpoint | Qwen3.5/Next both use GatedDeltaNet hybrid; reasonable but unconfirmed bet they follow it — **must be re-verified when they ship** |

For hybrid/sliding models we snapshot **all** per-layer caches at the
checkpoint (full-attention KV + Mamba `(conv,ssm)` + rotating window),
each via `extractBatched(row)`, and restore the whole set as a unit.
A model whose `newCache()` returns a type we don't yet handle (e.g.
`ChunkedKVCache`, `QuantizedKVCache`, `CacheList`, DeepseekV4's pooling
cache) is gated OUT of the prefix cache at load time — it runs cold,
no error.

## 5. File format

```
.darkbloom-kv  (one file per cache entry)

Offset  Size       Field                       Notes
──────  ──────     ───────────                  ──────────────────────
0       4          magic = "DBKV"               ASCII; version-stamped corpus
4       2          version (uint16 LE) = 1
6       2          flags (uint16 LE)            reserved; future compression bits
8       12         file_IV                      random; mixes into per-chunk nonces
20      4          wrapped_DEK length (LE)
24      N          wrapped_DEK                  AES-256-GCM(KEK, DEK)
                                                  = 12-byte nonce
                                                  ‖ 32-byte ciphertext
                                                  ‖ 16-byte tag (= 60B total)
24+N    4          metadata length (LE)
24+N+4  M          metadata                     JSON; used as AAD on chunk seal
                                                  see §5.1
24+N+4+M  ...      encrypted chunk stream       §5.2
```

### 5.1 Metadata (AAD)

```json
{
  "magic":            "DBKV",
  "format_version":   1,
  "model_hash":       "sha256:...",
  "model_dtype":      "bf16",
  "model_arch":       "Llama",
  "vocab_size":       128256,
  "num_layers":       32,
  "kv_heads":         8,
  "head_dim":         128,
  "token_count":      1843,
  "token_prefix_hash": "sha256:...",
  "kv_cache_class":   "KVCacheSimple",
  "meta_state":       ["..."],
  "created_at":       1716422400,
  "expires_at":       1717027200,
  "schema":           "darkbloom.kv.v1"
}
```

`metadata` is used **verbatim as AAD** on every chunk seal and on the
DEK wrap.

**What the AAD does and does NOT guarantee** (this distinction is
load-bearing — see §8.1.1):

- ✅ **Tamper-evidence.** Editing any metadata field *after* the file
  was written breaks the GCM tag on the DEK unwrap and every chunk.
  The read fails closed.
- ❌ **NOT model-binding.** On read, the AAD is the metadata block
  *read back from the same file* — it is self-describing, not checked
  against the live model. A structurally valid cache file authored for
  model A decrypts successfully even while model B is loaded. The
  crypto layer cannot tell "wrong model" from "right model" because
  both use the file's own metadata as AAD.

Therefore `model_hash` in the metadata is necessary but **not
sufficient** on its own. The "right model" guarantee is an
*application-layer equality check* the reader must perform explicitly
(§8.1.1). The crypto gives confidentiality + tamper-evidence; model
correctness is enforced one layer up.

### 5.2 Chunked ciphertext

One chunk per K or V tensor per layer:

```
For chunk i (i = 0, 1, ..., 2*num_layers - 1):
  ┌──────────────┬──────────────────┬────────────────┐
  │ length (4B)  │ ciphertext (var) │ tag (16B)       │
  └──────────────┴──────────────────┴────────────────┘

  nonce_i = HKDF-Extract(salt=file_IV, IKM=DEK)
            then HKDF-Expand("dbkv-chunk-" || uint32_be(i), 12)

  AES-256-GCM(DEK, nonce_i, AAD=metadata_bytes, plaintext=tensor_bytes_le)
```

Why chunked:
- Decrypt-on-stream into per-layer MLXArray buffers without holding the
  whole plaintext in RAM at once.
- Skip layers we don't need (won't happen in v1 but useful later for
  sliding-window or quantized variants).

Why HKDF-derived nonces instead of counter mode:
- Different files (different `file_IV`) always have different per-chunk
  nonces even if they share a DEK (they don't — but defense in depth).
- Per-chunk nonce can't be predicted by an attacker from chunk index
  alone without knowing the DEK.

Why per-file DEK rather than just per-file IV with shared key:
- Compromise of one cache file's DEK leaks only that file.
- DEKs are revocable by deleting the wrapped DEK from disk; the
  file becomes permanently unreadable without rotating the KEK.

## 6. Cryptography & key management

### 6.1 KEK (Key-Encrypting Key)

One KEK per provider, lifetime = provider lifetime.

**Storage:** `kSecClassGenericPassword` in the existing Keychain access
group used by the persistent SE identity, with:

```swift
let attrs: [CFString: Any] = [
  kSecClass:           kSecClassGenericPassword,
  kSecAttrService:     "io.darkbloom.kv.kek",
  kSecAttrAccount:     providerID,             // single account
  kSecValueData:       wrappedKEK,             // see below
  kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlock,
                                                // background daemon use
  kSecAttrSynchronizable: false,                // no iCloud sync
]
```

**Wrapping:** the raw 32-byte KEK material is generated by
`SymmetricKey(size: .bits256)` (CryptoKit) on first run, then wrapped
by an SE-derived key:

1. SE persistent ECDSA-P256 identity already exists (attestation).
2. Compute `wrap_secret = HKDF-SHA256(salt="dbkv-kek-v1",
   ikm=SE_signature_over("dbkv-kek-derivation-v1"))`.
   The SE signature is deterministic for our purposes because we sign
   a fixed string and rely on the SE's private key — not the
   signature's randomness — for the secret.
3. Wrap KEK with `ChaCha20-Poly1305(wrap_secret, KEK)`. Result stored
   in Keychain.
4. To unwrap on startup: re-sign the same fixed string, re-derive
   `wrap_secret`, decrypt.

**Why this and not just "store KEK in Keychain"?** Keychain alone gates
on filesystem ACL + login keychain unlock. Adding an SE-derived wrap
means an attacker who exfiltrates the keychain DB *and* a memory
dump still needs the SE key to recover the KEK. The SE key cannot be
extracted — only used.

**Rotation:** generate a new KEK + re-wrap all existing DEKs. Old
ciphertext is decrypted with the old KEK, re-encrypted with the new
DEK. Not needed for v1; design accommodates it via the wrap version
in metadata. `[Q2]`

### 6.2 DEK (Data-Encrypting Key)

Random 32-byte key per cache file. Generated by
`SymmetricKey(size: .bits256)`. Wrapped with the KEK using AES-256-GCM:

```
wrapped_DEK = AES-256-GCM(
  key   = KEK,
  nonce = random_12_bytes,                 // freshly generated per file
  AAD   = file_magic || version || file_IV,
  plain = DEK_raw_32_bytes
)
                                             // = 60 bytes total
```

DEK lives in process memory only after the file is opened. Zeroed on
process exit / explicit cache eviction.

### 6.3 Why CryptoKit primitives only

- All crypto is via `Apple CryptoKit` (AES-GCM, ChaCha20-Poly1305,
  HKDF-SHA256, P-256). No third-party crypto libraries.
- The SE bridge uses existing `SecureEnclaveIdentity` (already
  in use for attestation).

## 7. Index file

> **AS-BUILT (supersedes the SQLite sketch below):** there is **no SQLite
> dependency**. The index is a per-model-dir **JSON file** `index.json` under
> `kv/<modelKey>/`, loaded into memory and written back atomically — see
> `PrefixCacheIndex.swift` (top-of-file: *"No SQLite dependency"*;
> `PrefixIndexEntry: Codable`, `JSONEncoder`/`JSONDecoder`). Per-dir scoping
> replaces the global `model_hash` column; writes are coalesced
> (`saveCoalesceThreshold`) and crash-reconciled by `reconcileWithDisk()`. The
> SQL schema below is retained only as the original design record.

`~/.cache/darkbloom/kv/prefix-index.dbkv-idx` is a single SQLite
database (we already link `SQLite.swift` indirectly via Hummingbird's
dep graph — confirm). `[Q3]`

```sql
CREATE TABLE prefix_cache (
  id              INTEGER PRIMARY KEY,
  model_hash      TEXT NOT NULL,
  prefix_digest   BLOB NOT NULL,        -- SHA-256 of token IDs [0..N]
  token_count     INTEGER NOT NULL,
  parent_digest   BLOB,                 -- digest of [0..N/2] for tree traversal
  file_path       TEXT NOT NULL,
  file_size       INTEGER NOT NULL,
  created_at      INTEGER NOT NULL,
  last_hit_at     INTEGER NOT NULL,
  hit_count       INTEGER DEFAULT 0
);
CREATE INDEX idx_prefix_lookup ON prefix_cache (model_hash, token_count);
CREATE INDEX idx_lru          ON prefix_cache (last_hit_at);
```

Each cached entry is keyed by the SHA-256 of its token-ID array. Longest
prefix match is done by:

1. Compute the digest sequence for the incoming prompt at multiple
   checkpoints: `H[256], H[512], H[1024], H[2048], H[4096], H[8192]`.
2. Lookup each digest in the table.
3. Pick the largest `token_count` that matches.

Checkpoint granularity is a tradeoff: coarser saves digest CPU, finer
gives better prefix utilization. Default proposed: powers of 2 from
256 to 8192. `[Q4]`

## 8. Integration points

### 8.1 Read path (BatchScheduler)

`BatchScheduler.submitTokenized(promptTokens:...)` (currently at
`provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift:290`)
gains a `prefixCache` lookup step before slot reservation:

```swift
// Pseudocode
let prefixMatch = await prefixCache.lookup(
    modelHash: currentModelHash,
    tokens: promptTokens
)

if let match = prefixMatch {
    // Seed the new BatchKVCache row from match.state arrays,
    // skipping prefill on tokens[0..<match.tokenCount].
    let prefillStart = match.tokenCount
    // ... existing path with offset
} else {
    let prefillStart = 0
    // ... existing path
}
```

The lookup is parallel with chat-template application and tokenization
in `ProviderLoop.handleInferenceRequest`. The MLXArray buffers from
`PrefixCacheRAM` are reference-counted; we use them directly in the
batch row without copy.

### 8.1.1 MANDATORY model-binding guard

> See the read-path flowchart:
> [`ssd-kv-cache-model-binding.png`](ssd-kv-cache-model-binding.png)
> (source: [`ssd-kv-cache-model-binding.mmd`](ssd-kv-cache-model-binding.mmd)).
> It shows where MB-1 sits — between metadata-read and decrypt — and why
> the AES-GCM layer alone would let a wrong-model file through. Open the
> SVG in a browser to see the flow animate; it renders statically when
> embedded as an image.

> **Invariant (MB-1):** before any cached KV tensors are seeded into a
> batch row, `PrefixCacheManager` MUST verify
> `loadedFile.metadata.modelHash == currentLoadedModelHash` and reject
> on mismatch. The encrypted-store layer does **not** enforce this
> (§5.1) — a valid file from the wrong model decrypts cleanly. Skipping
> this check feeds another model's KV state into the current model and
> silently produces garbage tokens with no error.

Why the crypto doesn't cover it: AES-GCM authenticates the file
against *its own* metadata (read back as AAD), proving the bytes
weren't altered since write — not that they belong to the model now in
memory. "Wrong model" and "right model" are indistinguishable to the
cipher because both supply the file's embedded metadata as AAD.

The check is cheap and happens before the DEK is even unwrapped — use
`EncryptedKVStore.readMetadataOnly(from:)`, which parses the metadata
without touching the KEK:

```swift
// In PrefixCacheManager.lookup, SSD tier:
let meta = try EncryptedKVStore.readMetadataOnly(from: fileURL)

// MB-1: reject cross-model files BEFORE unwrap/decrypt.
guard meta.modelHash == currentLoadedModelHash else {
    logger.warning("prefix cache file model mismatch — refusing",
                   metadata: ["file": "\(meta.modelHash)",
                              "loaded": "\(currentLoadedModelHash)"])
    metrics.increment("prefix_cache.model_mismatch")
    // Evict the misfiled entry from the index; fall through to cold prefill.
    await index.remove(fileURL)
    return nil
}

// Defense in depth: also assert architectural shape matches, in case
// two distinct models ever truncate to the same 12-char dir prefix.
guard meta.numLayers == model.numLayers,
      meta.kvHeads   == model.kvHeads,
      meta.headDim   == model.headDim else {
    metrics.increment("prefix_cache.shape_mismatch")
    await index.remove(fileURL)
    return nil
}

// Only now is it safe to unwrap + decrypt.
let (_, chunks) = try await EncryptedKVStore.read(from: fileURL, kek: kek)
```

The same equality check applies to the **RAM tier** — entries there are
keyed by `modelHash` in the dictionary, so a lookup keyed by
`currentLoadedModelHash` structurally cannot return another model's
entry. The directory layout (`<model-hash>/…`) plays the same role for
the SSD tier in the *common* case; MB-1 is the backstop for when a
symlink, an index bug, or a 12-char hash-prefix collision defeats the
path convention.

**Tests (P3):**
- `prefixCacheRejectsCrossModelFile` — write a file with model A's
  `modelHash`, attempt lookup while model B is "loaded", assert the
  result is `nil`, the index entry is removed, and `model_mismatch` is
  counted. Must fail if the guard is removed.
- `prefixCacheRejectsShapeMismatch` — same `modelHash` but mismatched
  `numLayers`; assert rejection.
- `prefixCacheModelBindingGuardRunsBeforeDecrypt` — supply a KEK that
  would throw on unwrap; assert the model-mismatch path returns `nil`
  *without* the KEK ever being consulted (proves ordering).

### 8.2 Write path (IdleMonitor + lifecycle)

Three triggers:

| Site | File | Existing function | Add |
|------|------|-------------------|-----|
| Idle unload | `ProviderLoop.swift` | `tickIdleMonitor` | flush model's `PrefixCacheRAM` before `unloadModel` |
| Graceful shutdown | `ProviderLoop.swift` | event-stream-end branch | flush ALL `PrefixCacheRAM` with a 10s deadline |
| Model swap | `ProviderLoop.swift` | `handleLoadModel` (coordinator-driven) | flush outgoing model's `PrefixCacheRAM` |

Writes are async and best-effort. A flush that doesn't complete in
time on shutdown drops the in-progress entries; SSD-tier entries from
before that flush survive (atomic-rename).

### 8.3 New types

```
provider-swift/Sources/ProviderCore/KVCache/
├── PrefixDigest.swift              // SHA-256 prefix digests, checkpoints
├── EncryptedKVStore.swift          // file format read/write
├── KVCacheKEK.swift                // KEK lifecycle + Keychain
├── KVCacheDEK.swift                // DEK wrap/unwrap
├── PrefixCacheRAM.swift            // in-process LRU
├── PrefixCacheIndex.swift          // SQLite index
└── PrefixCacheManager.swift        // public API; orchestrates the tiers
```

`PrefixCacheManager` is a Swift `actor`. Owned by `BatchScheduler` (one
per model) so we get the same actor-isolation discipline already used
elsewhere.

## 9. TTFT optimizations (the meat)

These are the design choices that make this worth shipping rather than
a "correctness-only" save/load. Each one was identified before code.

| # | Optimization | Why it matters | Where it lives |
|---|--------------|----------------|----------------|
| O1 | **Speculative SSD read.** Start the decrypt + load as soon as the first prefix digest is computed, before tokenization is even done. | TCP/SSD/AES latency is hidden behind tokenization (~5-30ms) and template application. | `PrefixCacheManager.speculativeLoad` |
| O2 | ~~**Longest-prefix match**~~ — **DROPPED** (see §2 non-goals, §4.4). Hybrid/sliding/recurrent models can't slice to a shorter prefix, so matching is **exact-checkpoint**: hit only when the incoming prompt's prefix is byte-identical to a cached checkpoint boundary. Checkpoints at the O9 boundaries (256/512/1k/2k/…) give multiple exact-match points per prompt. | Exact-checkpoint still catches the dominant case (shared system prompt). | `PrefixCacheIndex.findExactCheckpoint` |
| O3 | **Three-tier RAM/SSD/VRAM.** Hot prefixes stay decrypted in RAM. SSD is the *cold* path, not the *only* path. | Decrypt+load of a 270MB prefix (~2k tokens, 7B model) is ~80-200ms even with all the below tricks. RAM hit is ~5ms. | `PrefixCacheManager` orchestration |
| O4 | **Decrypt directly into MLXArray-shaped buffer.** AES-GCM chunk-at-a-time, write decrypted bytes into a pre-allocated MLX buffer; avoid the `Data → MLXArray(...)` round-trip. | Naive path doubles peak RAM and adds ~50-100ms per GB for memcpy. Worth profiling whether MLX's `MLXArray.init(data:dtype:shape:)` can avoid the copy. | `EncryptedKVStore.readInto` |
| O5 | **`mmap` the encrypted file.** Don't `Data(contentsOf:)`. Lets the kernel page in what we need. | A 1GB cache file fully loaded via `Data(contentsOf:)` spikes RSS by 1GB. mmap'd it stays in unified buffer cache. | `EncryptedKVStore.openMapped` |
| O6 | **Per-chunk-by-layer parallelism.** Decrypt layer K, V chunks in parallel (Swift `withTaskGroup`). | AES-GCM is CPU-bound; we have many cores idle during prefill warmup. 32 layers × 2 chunks = 64 parallel tasks, no contention. | `EncryptedKVStore.readAllChunks` |
| O7 | **DEK held in process memory.** SE unwrap of DEK is ~5-20ms; cache it for the open lifetime of the file. | One unwrap per file open, not per chunk. | `EncryptedKVStore.openMapped` |
| O8 | **Prewarm-on-load.** When a model loads, asynchronously pull the top-K most-recently-hit prefixes from SSD into RAM tier. | Removes cold-start tax for the first request after a restart. Bounded by RAM budget. | `PrefixCacheManager.warmTopK` |
| O9 | **Digest checkpoints align with prefill boundaries.** Cache at 256/512/1024/2048/4096/8192-token boundaries so a 1500-token request hits at 1024 and only prefills 476 tokens (not all 1500). | Random-length caches mean many requests miss by a small tail. Power-of-2 checkpoints give predictable hit rates. | `PrefixDigest.checkpointSizes` |

### 9.1 Expected TTFT impact (7B-class model on M3 Pro, fp16)

| Scenario | Today | With SSD KV (RAM hit) | With SSD KV (SSD hit) |
|----------|-------|-----------------------|-----------------------|
| 500-tok system prompt + short turn | ~1.4s | ~0.05s (97% ↓) | ~0.2s (86% ↓) |
| 2k-tok system prompt + short turn | ~5.2s | ~0.05s (99% ↓) | ~0.3s (94% ↓) |
| 8k-tok system prompt + short turn | ~20s | ~0.05s | ~1.0s (95% ↓) |
| Unique prompt (cache miss) | ~5s | ~5s (no change) | ~5s (no change) |

Numbers are rough — based on the existing benchmark in
`provider-swift/Tests/.../BatchingTests.swift` and a back-of-envelope
AES-GCM throughput estimate (~3 GB/s with AES-NI on M3). To be
re-measured during implementation. `[Q5]`

## 10. Failure modes

| Failure | Behavior |
|---------|----------|
| Keychain locked (first boot, no unlock) | Cache disabled this session. Log + metric. Inference works (cold path). |
| KEK unwrap fails (SE wiped, identity rotated) | Cache disabled. Index dropped. Old files deleted lazily (next eviction). |
| DEK unwrap fails for a single file | That file deleted. Index entry removed. Continue with cold prefill. |
| AES-GCM auth tag mismatch | Same — file deleted, log, continue. |
| **Cross-model file (right hash dir, wrong model loaded)** | **Caught by the MB-1 guard (§8.1.1), not the crypto — decrypts cleanly otherwise.** Entry removed from index, `model_mismatch` counted, cold prefill. |
| **Architectural-shape mismatch (12-char hash-prefix collision)** | Caught by the shape guard (§8.1.1). Entry removed, `shape_mismatch` counted, cold prefill. |
| Disk full on write | Refuse to write. Existing entries untouched. Future eviction sweeps may reclaim. |
| Index DB corrupt | Rebuild from filesystem scan (each file is self-describing). |
| Process crash mid-write | Atomic-rename ensures partial files never appear in the index. Tmp file orphan cleaned on next startup. |
| Model swap mid-flush | Outgoing model's flush is cancelled if it doesn't finish by deadline; partial entries dropped (atomic-rename). |

## 11. Disk usage & eviction

Per-model on-SSD budget. Default proposed: **20 GB per model**, total
**80 GB** across all models. Eviction policy: LRU by `last_hit_at`.
`[Q6]`

Sizes for reference (Llama-3.2-1B in bf16, 16 layers, 8 KV heads, head_dim 64):

| Prefix length | Plaintext bytes | Encrypted file size |
|---------------|-----------------|---------------------|
| 256 tokens | 8 MB | ~8.1 MB |
| 1k tokens | 33 MB | ~33.1 MB |
| 8k tokens | 268 MB | ~268.5 MB |

Overhead is negligible (chunk lengths + nonces + tags ≈ 0.05%).

## 12. Telemetry

New per-request fields, additive to existing `X-Timing`:

| Field | Type | Notes |
|-------|------|-------|
| `prefix_cache_tier` | enum | `vram` / `ram` / `ssd` / `miss` |
| `prefix_cache_tokens` | int | tokens skipped by prefix match |
| `prefix_cache_load_ms` | float | SSD read + decrypt latency (0 if RAM/miss) |

No plaintext, no prompt fragments — same allowlist discipline as
existing telemetry. See `docs/telemetry.md`.

## 13. Out of scope & follow-ups

- Sharing prefix caches across providers (would need a coordinator
  protocol + key escrow + threat-model refresh)
- Quantized KV cache to compress SSD footprint
- Prefix caches for TP/PP cluster sessions
- Per-tenant prefix cache isolation (today: a single provider's cache
  is shared across all consumers; we rely on encryption-at-rest, not
  consumer-side scoping). `[Q7]`

## 14. Phased delivery

| Phase | Scope | Test |
|-------|-------|------|
| **P0** | EncryptedKVStore (write + read roundtrip), KEK + DEK, no integration | Unit tests w/ fixed-byte fixtures; tamper tests; tag-mismatch tests |
| **P1** | PrefixCacheRAM (LRU, no SSD) | Unit tests; correctness vs cold prefill |
| **P2** | PrefixCacheIndex (SQLite, prefix-match tree) | Unit + small integration; concurrent insert/lookup |
| **P3** | Integration into BatchScheduler.submitTokenized read path **+ MB-1 model-binding guard (§8.1.1)** | Integration: run benchmark, observe TTFT drop; **cross-model + shape-mismatch rejection tests that fail if the guard is removed** |
| **P4** | Idle-unload + shutdown flush write paths | Process-restart roundtrip test |
| **P5** | TTFT optimizations O4–O8 (mmap, parallel chunks, prewarm) | Microbenchmarks before/after each |
| **P6** | Telemetry, disk budget enforcement, eviction | E2E test with budget exhaustion |

Each phase is its own commit / PR. Phases 0-2 ship behind a feature
flag so they're inert until P3 wires the read path.

## 15. Open questions for review

**Resolved by verification (no longer open):**
- ~~Can hybrid/sliding models (Qwen3.5/Next MoE, Gemma-4 MoE, GPT-OSS)
  be prefix-cached?~~ **YES, exact-checkpoint** — verified §4.4/§4.5,
  proven by the rotating-restore tests. MoE is irrelevant to the KV path.
- ~~Does the sliding-window (rotating) cache survive snapshot/restore?~~
  **YES** when `state`+`metaState` restored together (invariant MS-1),
  proven empirically.
- ~~Does upstream save/load support the batched caches we run?~~ Moot —
  we `extractBatched(row)` first, yielding single-stream caches the
  upstream path does handle.

**Still open:**
- `[Q1]` First-cut excludes cluster (TP/PP) prefix caching. Confirm OK,
  or do you need it from day one?
- `[Q8]` **Exact-checkpoint match is now the only mode** (longest-prefix
  dropped, §2). Confirm that's acceptable — it covers shared-system-
  prompt reuse but not partial-prefix overlap. If partial overlap on
  pure-attention models is valuable enough, we could special-case those
  (added complexity).
- `[Q2]` KEK rotation: design accommodates it but v1 has no UX for
  triggering it. Acceptable?
- `[Q3]` SQLite for the index, or do you prefer a simpler approach
  (plain JSON file scanned at startup, tree built in RAM)? Index is
  small (a few MB max), so JSON is viable.
- `[Q4]` Digest checkpoint granularity (256, 512, 1024, 2048, 4096,
  8192). Adjust the set, or skip this and digest every N tokens with
  a fixed N?
- `[Q5]` Should the TTFT estimates be backed by a real benchmark
  *before* phase P3 ships, or is the "we'll measure during P3 and
  course-correct" plan sufficient?
- `[Q6]` Disk budget defaults: 20 GB/model, 80 GB total. Comfortable
  with these? Configurable via provider.toml.
- `[Q7]` Per-tenant isolation: today's design has one cache per
  *provider* (shared across consumers on that provider). If a future
  multi-tenant guarantee requires per-consumer isolation, we'd need
  to add a consumer-derived key into the AAD. Want this in v1?

## Appendix A: Concrete file path layout

```
~/.cache/darkbloom/kv/
├── prefix-index.dbkv-idx          # SQLite
├── tmp/                            # for atomic rename
└── <model-hash-12char>/
    ├── 0a4f8c2e91b6...4d.darkbloom-kv
    ├── 18c0e5b3a8f1...77.darkbloom-kv
    └── ...
```

`<model-hash-12char>` = first 12 hex chars of SHA-256(model weights);
matches the existing model identifier used elsewhere in the provider.
