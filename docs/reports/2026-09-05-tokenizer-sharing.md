# Shared tokenizer ownership and sidecar load check

> Last updated: 2026-09-05 · commit `1114a8ba0`

The prompt sidecar now shares parsed tokenizers across contracts with identical,
verified tokenizer bytes. In one ordered local macOS comparison, cold-load peak
RSS fell from 962.75 to 653.41 MiB and warm peak RSS from 903.59 to 560.75 MiB.
All compared plans remained exact. Warm planning latency was approximately
2.16 ms in both arms; this result establishes no warm latency improvement.

The [evidence manifest](evidence/tokenizer-sharing-2026-09-05/manifest.json)
preserves both results, exact commands and binary hashes, source hashes, build
logs, tests and the initial corrected compile failure. The parent independently
verified all 13 stored/raw payloads and all 51 captured source hashes before
banking this milestone. The source baseline is `59e8a7bb2`; the intervening
physical-admission commit changes no sidecar source.

## Ownership change

The existing contract `SingleflightLru` retains loaded artifacts strongly.
A second cache uses the same concurrency implementation with weak retention,
keyed by the verified `tokenizer.json` SHA-256. `LoadedArtifacts` owns an
`Arc<Tokenizer>`; the weak cache cannot extend the lifetime of an otherwise
unused tokenizer. Its metadata has the same configured capacity bound as the
contract cache. Concurrent constructors for one digest share a flight.

Each contract still opens, reads and verifies every declared artifact before
reusing a tokenizer. A warm digest cannot hide corrupted bytes in another
contract directory. Model metadata, tokenizer configuration and templates
remain contract-specific. Only the immutable object parsed from tokenizer JSON
is shared; encoding still disables added special tokens. Renderer and
normalization versions, contract IDs and committed vectors are unchanged.

Tests cover shared ownership across independent contracts, distinct tokenizer
digests, warm-cache integrity rejection, weak expiry, concurrent construction
and retries after failed loads. Existing cache/artifact tests moved into child
test modules; those moves are not claimed as code deletion.

## Validation

All 111 Rust tests, strict all-target Clippy and the Go load-proof package
passed. The release fixture generator reproduced all 98 vectors byte-for-byte
for seven model entries and six unique contracts. Vector SHA-256:
`7bda5110dac22a0ab24d0b28a6502935de70d2571037a58dd77f3cad17cc0430`.
The initial library compile exposed an existing renderer test constructor that
needed the new `Arc`; it was corrected before the full suite and comparison.

Both arms used the same new Go proof executable, identical artifacts, 25 QPS
for 15 seconds, a 1024 MiB RSS ceiling and a 128 MiB growth ceiling. Each passed
96 cold requests and 375 warm requests with zero mismatches or restarts.

| Measurement | Baseline | Shared tokenizer |
|---|---:|---:|
| Cold-load peak RSS, MiB | 962.75 | 653.41 |
| Warm peak RSS, MiB | 903.59 | 560.75 |
| Seven cold loads including seed, mean ms | 197.95 | 104.53 |
| Six-contract preload, mean ms | 197.72 | 112.18 |
| Warm plan, mean ms | 2.1581 | 2.1645 |

Means come from cumulative microseconds divided by counts. Histograms have
cumulative upper-bound buckets; no exact quantiles are inferred. This was one
baseline-then-candidate pair in a quiet CPU window. OS file caches were
uncontrolled: cold means construction in a fresh process, not a cold disk.
Darwin RSS does not establish the production Linux musl address-space limit.
Native Linux/amd64 validation remains required. No Swift model, end-to-end
inference or production rollout claim follows from this sidecar measurement.
