# Correct attention metadata owner identity for production caches

> Last updated: 2026-09-06 · commit `c9bd3ab78`

The diagnostic now binds each concrete cache to its dense storage owner explicitly.
The actual Qwen production adapter keeps its original cache indices. Native
regressions and a tiny actual-family provider test pass. The corrected diagnostic
has not yet been rerun against the real Qwen artifact; numerical parity remains open.

## Failure and correction

The first real Qwen metadata attempt exposed a diagnostic mapping bug. Contiguous
production caches carry model indices `3, 7, …, 39`; paged caches carry dense storage
indices `0…9`. The diagnostic treated either cache index as a dense owner, admitting
only contiguous caches 3 and 7 and refusing the other eight. The strict result was
`inconclusive`, even though the underlying sampled forward completed.

Native commit `e972340a7ba6e22fda5d8be1a7af918f9bf67b03` changes five files.
The selected forward binds each cache object, expected layer kind, original cache
index and dense storage position. Observation looks up that binding and rejects
wrong, unbound or repeated owners. This preserves cache indices and all backend
arithmetic. The binding contains host identity only; it adds no model forward,
tensor evaluation, readback or retained tensor. The existing default-nil selection,
forward defer and confirmed/discarded sample lifecycle remain in place.

## Validation

Six native filters pass: **33 test functions / 42 expanded cases**, with no skips
or source corrections. Three new functions / four cases cover dense and original
indices, wrong kind/index/storage, duplicate object/storage, unbound objects and
repeated observation. Existing actual-dtype metadata, ordinary direct/chained and
cancellation controls, logits and recurrent-state tests pass.

One provider regression constructs the actual `Qwen35MoEModel`, production backend
factory and production adapter with a tiny 40-layer configuration. It verifies all
ten original contiguous cache indices remain unchanged, all ten dense metadata
owners are recorded, the selected seed/target is confirmed, cache bindings clear,
and control/capture generated tokens match. This is a real model-family unit test,
not a test of the large target weights.

Native and provider builds complete in 51.52 and 101.31 seconds. Frozen source
verification covers 897 native and 683 provider compile inputs, 1,356 dependency
files and 27 Jinja files. Retained build graphs match 761 native and 1,258 provider
declared source references. These graph counts do not assert that every graph
entry links into the selected test product. Pinned local MLX supplies compiled
sources; an unused remote SwiftPM checkout is not compilation identity evidence.

## Preserved real-model attempt before the fix

The archive retains all four original cells, their inputs, reports, telemetry and
comparisons. All used cache-off, MTP-off and the same 5,523-token prompt.

| Backend | Trace | Original result |
| --- | --- | --- |
| Contiguous | Off | Report integrity passed |
| Contiguous | On | Inconclusive metadata: 2 of 10 owners; strict attempt failed |
| Paged | Off | Report integrity passed |
| Paged | On | Complete confirmed metadata for all 10 owners |

Within each backend, all seven completed trajectories match between control and
trace. Asynchronous cancellation emits three versus four tokens; both remain
prefixes of recovery output. Cross-backend output still first differs at position
62: contiguous selects 1928 and paged selects 6829, following seed 11346.

The paged trace observes BF16 Q, incoming/stored K/V and output at all ten owners,
with segmented decode, Q shape `[1,16,1,256]` and K/V input shape `[1,2,1,256]`.
Offsets advance from 5,584 to 5,585. These observations concern that selected step;
they do not establish equal tensor contents or historical storage correctness.

## Evidence and remaining work

The [manifest](evidence/attention-owner-identity-2026-09-06/manifest.json) and
[archive](evidence/attention-owner-identity-2026-09-06/payloads.tar.gz) preserve
179 rehashed payloads, 10,246,902 uncompressed bytes. The archive is 3,051,803 bytes;
compiled binaries and model weights are excluded.

Manifest SHA-256: `ac081ec79da8754ba1117b4808109ab9aed7800ad8274a206d1ab880a0fa84d0`.
Archive SHA-256: `cc719a6f495c9b3325814f3ef12e1225d3fb6e9c126d19fc99484f955900c60d`.

A corrected probe build and separately reviewed real-model rerun remain pending.
Bounded raw attention packets, same-input replay/reference and an independent
history mirror remain separate numerical proof requirements. This milestone
does not establish a speedup, release readiness or a change to cache defaults.
