# Exact-prefix holder index check

> Last updated: 2026-09-05 · commit `363588e64`

This coordinator change makes the holder limit apply across independent provider
epochs and removes the fleet-sized capability/hash walk before scheduling.
It changes the lookup index, not cache pricing, admission or provider behavior.
The separately frozen [source blobs](evidence/2026-09-05-cache-holder-index/index-final-blobs.json)
and [evidence manifest](evidence/2026-09-05-cache-holder-index/manifest.json) identify this milestone;
subsequent service-cost scoring is outside its scope.

## Behavior

The internal content key binds tenant scope, artifact, prompt contract and exact
boundary. Provider epoch remains mandatory holder metadata. Independent machines
therefore share one bounded bucket per content prefix and tier: the default limit
is four machines, while SSD and memory keep separate evidence. Misses, reconnects
and epoch changes invalidate only the affected provider. Nonces, capability
quarantine, connection identity and reservation revision checks remain enforced.

For `B` boundaries and a configured maximum of `H` holders per bucket, lookup
computes `B` keyed digests, queries at most `2 × B × H` records, then inspects only
matching providers. The ordinary eligibility scan remains. A holder miss skips
registry/capability work; no cache hint bypasses admission.

## Checks

Pinned Go 1.25.0 registry and routing-simulation suites passed normally and under
race detection. Final full-package race times were 23.451 s and 3.449 s; the later
empty-match fast return passed affected race tests in 2.672 s. New regressions
cover eight different epochs under a four-machine cap, epoch/miss/reconnect and
replay isolation, tenant/artifact/tier separation, and lookup completing while an
unrelated provider lock is deliberately held. Existing cross-machine original
prompt/continuation, malformed receipt and capacity tests also passed.

[Normal log](evidence/2026-09-05-cache-holder-index/registry-tests.log.gz),
[final full race log](evidence/2026-09-05-cache-holder-index/registry-races-final.log.gz),
[empty-match race log](evidence/2026-09-05-cache-holder-index/index-empty-miss-races.log.gz).
These ran in the shared integration worktree alongside date/telemetry changes;
the retained manifest captures the changed index files, not a complete clean-tree
build. An independent checkout at `363588e64` with only the 13 frozen index files
also passed both complete package suites under race detection (23.479 s /
3.757 s). Its full 863-file Go source manifest and log are retained as
`index-isolated-go-*` in the evidence directory. Documentation lint passed for
135 files before this report was added.

## Local lookup benchmark

Apple M3 Max; one process; 64 boundaries and four matching machines; median of
three 100 ms samples. Both arms assert the same four results. The legacy reference
retains the previous provider-by-boundary epoch-key algorithm but omits some old
capability-map/validation overhead. The index arm calls the production helper.

| Providers | Legacy reference, μs/op | Content index, μs/op | Legacy B/op | Index B/op | Legacy allocations/op | Index allocations/op |
|---:|---:|---:|---:|---:|---:|---:|
| 16 | 540.787 | 46.295 | 968,973 | 72,328 | 16,206 | 1,166 |
| 128 | 4,939.358 | 44.689 | 8,675,591 | 72,329 | 145,230 | 1,166 |
| 512 | 23,462.942 | 51.444 | 35,099,536 | 72,329 | 587,604 | 1,166 |

Reproduce the frozen benchmark with:

```sh
GOTOOLCHAIN=go1.25.0 go test ./coordinator/registry -run '^$' \
  -bench '^BenchmarkCacheHolderIndex$' -benchtime=100ms -count=3
```

[Raw samples](evidence/2026-09-05-cache-holder-index/index-benchmark.log.gz).
The useful result is that unrelated fleet growth no longer increases lookup
work or allocations. These samples precede the empty-match-only follow-up;
all benchmark cases contain holders. They exclude sidecar rendering, the normal
scheduler scan, queueing, network, disk staging and GPU work. They establish no
live multi-provider latency gain or production rollout.
