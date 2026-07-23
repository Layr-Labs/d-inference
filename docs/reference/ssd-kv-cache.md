# SSD KV Cache Reference

This is the current reference for the ContinuousBatchingV2 encrypted SSD prefix
cache, including the `cbv2-frozen-full-3` hybrid replay semantics. The
pre-v0.7.5 `BatchScheduler`, `PrefixCacheManager`, and
`EncryptedPrefixCachePersistence` implementations are retired.

## Status

The encrypted SSD tier is selected by default for CBv2-supported models. It
keeps the engine's full live-KV memory grant and stores donated prefix blocks
under `~/Library/Caches/darkbloom/kv3/`.

| State | Selection | Memory behavior |
|---|---|---|
| Encrypted SSD | Default, unless a kill switch disables it | No persistent RAM carve; read staging is reserved per staged entry; bounded host buffers back the write-behind queue |
| Off | `DARKBLOOM_PREFIX_CACHE=0` | Entire slot grant remains available for live KV |

Production has no RAM prefix-cache mode and performs no persistent KV-memory
carve. The single production gate is
`ProviderCore/Inference/PrefixCachePolicy.swift`.

The SSD tier requires the Secure-Enclave-rooted KEK. If key creation is not
available, it fails closed to uncached serving. The ephemeral KEK escape hatch
is for unsigned tests only and does not preserve cache data across restarts.

## Request flow

1. `EngineV2` hashes 256-token prefix blocks with the model and request cache
   scope.
2. `SSDPrefixCache` probes its in-memory HMAC-tag index before submission.
3. On a hit, it reserves staging bytes in `GlobalKVCacheBudget`, reads and
   authenticates a contiguous block run, and seeds the engine's staging map.
4. ContinuousBatchingV2 derives a typed M/C/R plan. Safe layouts restore full
   rows through C. Interleaved contiguous native-float hybrids restore owning full rows
   through M and keep them immutable while replay rebuilds sliding rows from C.
5. Completed requests donate eligible block snapshots to a bounded write-behind
   queue. Admission, write-rate, low-disk, TTL, and box-wide LRU guards apply.

Structurally safe layouts preserve their existing direct/tail-replay path.
Interleaved hybrids use frozen-full replay on contiguous unquantized rows. Paged
hybrids, quantized rows, and unknown layouts fail cold. Eligible layouts persist
a donation only when it also clears the configured effective-token floor. See
[`ssd-kv-cache-hybrid-models.md`](./ssd-kv-cache-hybrid-models.md).

## Eligibility and donation telemetry

Each loaded provider slot produces a bounded `prefix_cache_statuses` entry from
its actual cache-construction state. `ready` is emitted only after the startup
disk scan and cache epoch are usable. Before that the slot is
`pending/scan_pending`; scan failure is `error/scan_failed`. Configuration,
weight identity, layout/backend support, disk setup, and initialization failures
use the fixed reason vocabulary documented in
[`cache-aware-routing.md`](../architecture/cache-aware-routing.md). A provider
advertises exact protocol v2 only when at least one slot is actually ready; the
status snapshot still explains every loaded v1 slot. Ready status and v2
capability are published from one reconciled snapshot: ready requires a
concrete backend and replay strategy, and each capability requires one ready
status when optional telemetry is present. Unloaded models emit no status.

Every call into the SSD donation path settles exactly one process-local outcome:

`donated`, `below_effective_token_floor`, `no_complete_block`,
`lossy_snapshot`, `incomplete_layer_state`, `stage_size_exceeded`,
`write_rate_limited`, `write_queue_full`, `already_durable`, `already_queued`,
`cache_closed`, `disk_unavailable`, or `write_failed`.

If cache teardown races a write already executing, a successful durable write
is classified `cache_closed` for both correlated and uncorrelated donations
because ready-receipt delivery can no longer complete. A real write failure
remains `write_failed`; ordinary successful completion remains `donated`. The
per-opportunity settlement box still records exactly one outcome.

These are cumulative counters, not per-request events. The provider sends only
the fixed enum and count. No model/request/provider identifier, path, token,
prompt, cache scope, hash, epoch, account, serial, or free-form error is retained
or sent. The coordinator baselines registration, consumes monotonic heartbeat
deltas, and exports aggregate outcomes through `/v1/cache/status`, Prometheus,
and Datadog. Optional status/outcome fields are forward-compatible and
non-fatal: unknown entries are dropped, structurally ambiguous/oversized
snapshots are discarded within fixed bounds, and provider registration remains
available. Donation input accepts at most 32 raw entries while aggregating only
the 13 known outcomes, leaving fixed forward-version headroom without adding
metric buckets. Routing capability fields remain independently strict.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | unset/on | Single production kill switch; any explicit non-affirmative value disables encrypted SSD |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | min(20 GiB, free/2) | Box-wide SSD budget |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | 900 | Sliding TTL; overrides can only shorten the 15-minute maximum |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | 1024 | Generic minimum saved tokens; frozen hybrids with R ≥ 25,600 enforce at least 1,536 from real Gemma evidence |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` | 1024 | Per-request staging-memory cap |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | 1000 | Maximum estimated staging time |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | 150 | Daily endurance limit; `0` means unlimited |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` | disabled | Unsigned test-only in-memory KEK |

Installed launchd services preserve `DARKBLOOM_PREFIX_CACHE`. The remaining
tuning variables are available to foreground/test processes or must be added
explicitly to the launchd environment with `launchctl`; exporting them in an
interactive shell does not change an already-installed daemon. The passthrough
allowlist is in `ProviderCore/Service/LaunchAgent.swift`.

Writes stop when free space drops below the greater of 20 GiB or 5% of the
volume. Reads remain available. An ENOSPC write starts a ten-minute write
cooldown.

## Storage and cryptography

Each model uses `~/Library/Caches/darkbloom/kv3/<modelKey>/`, where `modelKey`
is the first 12 hex characters of SHA-256(model ID). Each `.dbk3` file contains
one 256-token KV block. Files are AES-256-GCM encrypted with a fresh DEK wrapped
by the Secure-Enclave-rooted KEK; canonical metadata is authenticated as AAD.

File names and the in-memory index use truncated HMAC-SHA256 lookup tags derived
from the KEK. The full tag is authenticated in metadata. Raw token IDs, raw
prefix hashes, request IDs, and cache-scope values never touch disk.
Reusable entries require both a verified weight hash and a prompt contract
computed from the loaded model's tokenizer, template, and config artifacts.
If either identity is unavailable, the SSD tier stays disabled. Reads also
verify that binding, the `cbv2-frozen-full-3` layout epoch, block size, and full
lookup tag. Any parse, binding, or authentication failure is deleted and
treated as a cold miss. Upgrading from `cbv2-snap-2` rotates the per-model cache
epoch and purges old blocks before readiness is advertised; DBK3 itself is
unchanged.

The legacy `darkbloom/kv/` tree is swept on startup. The `kv3/` root is
separate and is not touched by that cleanup; the retired `kv2/` layout is
ignored after the hash-contract rotation.

## Security boundary

Encryption and HMAC-keyed names close the legacy disk confirmation oracle. A
shared prefix can still change time-to-first-token inside the trusted provider
process, and SSD warmth can survive restart within the 15-minute TTL. Request
cache scope narrows that channel; `DARKBLOOM_PREFIX_CACHE=0` removes it.

## Code locations

| Concern | File |
|---|---|
| Production gate and SSD budget | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` |
| Slot wiring | `provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift` |
| Engine integration | `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift` |
| SSD cache | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift` |
| File codec | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockStore.swift` |
| HMAC lookup names | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLookupKeys.swift` |
| TTL and box-wide LRU | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockIndex.swift` |
| Write-behind and endurance | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBehind.swift` |
| Tests | `provider-swift/Tests/ProviderCoreTests/SSDPrefixCacheTests.swift` |
