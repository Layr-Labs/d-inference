# Memory reservation retirement follows ownership

> Last updated: 2026-09-05 · commit `966eac55c`

`GlobalKVCacheBudget` no longer refunds an old reservation during a sustained
rejection audit. A long decode or pending load keeps its charge until explicit
retirement. The focused regression run passes 99 functions / 100 cases, including
the surrounding load, cancellation, shutdown and SSD staging paths.

## Behavior and cleanup

Previously, continued capacity rejection could remove reservations older than
the stale TTL. Age did not prove that their native buffers or pending allocations
had retired. The timer-based refund loop and TTL configuration are deleted.
Rate-limited rejection diagnostics and background allocator-cache reclamation
remain; actual releases and successful admissions reset the diagnostic streak.

The audit has an injected monotonic clock. Five focused test functions / six
cases replace the older sleep-based audit tests. Both a decode and a pending-load
owner retain a 6 GiB reservation after aging 601 seconds and across 25 rejections
over another 240 seconds. The three audit events do not refund either owner;
explicit release makes the same capacity available to its replacement. Other
cases verify rate limits, idle gaps, unknown releases and successful admissions.

## Validation and source identity

Parent base `966eac55cf88057564730d64f3d17802486d54d3`, native engine
`326d9a27a9227e1636a7a584687193d425f0b4b0`. The source freeze contains three
Swift files: the budget implementation, its existing tests and the new audit
suite. All three hashes and 1,118 selected source-input hashes match before and
after execution; dependency pins were unchanged.

| Group | Functions / cases | Result | Test time |
|---|---:|---|---:|
| Budget, audit and reclaimer | 31 / 32 | Pass | 0.509 s |
| Model load, bridge lifecycle/capacity and SSD reservations | 68 / 68 | Pass | 0.904 s |

The single build reports 36.98 seconds. No selected case failed or skipped.
Exact commands, test identifiers and logs are retained in the
[evidence manifest](evidence/kv-owner-retirement-2026-09-05/manifest.json).
Its 17 compressed payloads include source archives and before/after source
identities. Stored and decompressed hashes match the original evidence. Manifest
SHA-256: `3dad3e498550ee6ea78dea8b5c1a520ca8a4108a779e198cb2e02ce9bbec4cbe`.

This closes the age-only refund path. It does not establish the later shared
native/process ledger, real-model usable capacity or performance. Explicit
release correctness still depends on the actual owner lifecycle.
