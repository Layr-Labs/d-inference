# Provider-aligned cache service-cost check

> Last updated: 2026-09-05 · commit `8ada7e548`

Verified prefix reuse now reduces the prefill component of coordinator service
cost by its expected time saving after SSD staging. The estimate follows the
provider's executable cache tier and longest verified endpoint. All 25 Go
packages passed in an isolated checkout containing the final 31 source blobs.
The [evidence manifest](evidence/2026-09-05-cache-service-cost/manifest.json)
identifies those sources, checks and measurement limits.

## Behavior

`cacheServiceCredit` uses the same prefill rate and long-prompt amplification
as the candidate's cold estimate. It weights saved prefill by the holder's
remaining lifetime, subtracts the full recorded staging cost, and bounds credit
by the prefill work charged to this request. The linear age weighting is an
explicit policy, not a measured hit probability. Load, decode, queue, pending,
backlog, health and capacity terms remain charged. Full prompt admission and
cold TTFT eligibility gates still apply.

A pool containing positive cache credit selects its minimum adjusted service
cost, using queue and pending counts only for exact ties. A pool without credit
retains the previous near-cost load spreading. The unreachable current
`cache_tiebreak` selection branch was removed; historical stored values remain
readable.

The scalar hint describes the longest verified endpoint the provider can select.
Complete SSD takes precedence over resident state; missing SSD evidence does
not grant resident credit when a complete capability is present. Other ambiguous
dual-tier advertisements receive no credit. The separately banked
[provider tier change](2026-09-05-provider-cache-tier.md) suppresses resident
evidence when an accepted complete store owns selection. Unknown newer local
endpoints, eviction and staging refusal can still change actual reuse: this is
an advisory routing estimate. No endpoint steering was added to the wire.

Optional caps now distinguish absent values from explicit zero. Absent or blank
caps leave the prefill-work bound in force; zero disables credit. Configuration
validates finite ranges and owns its pointer values. Release-env refresh migrates
only the exact stock pair `1000` / `0.35` to blank together. Any customized pair
or explicit zero is preserved, and refresh is idempotent. An intentionally
retained exact stock pair cannot be distinguished from stock; the existing
`--check` mode exposes that migration for review. No production environment was
read or changed, and routing mode, cohort and QPS defaults remain unchanged.

## Validation

The final implementation passed complete registry and routing-simulation suites
normally (15.982 s / 0.549 s) and under race detection (23.496 s / 3.754 s).
The last resident-only and longest-endpoint regressions passed under race
detection in 1.513 s. Environment tests cover stock and customized cap pairs,
zeros, repeat refresh, read-only checks and existing key/backup handling.

Independent checkout `b1e1581fc` plus the exact 31 frozen blobs passed
`GOTOOLCHAIN=go1.25.0 go test -p 2 ./coordinator/... -count=1` across all 25
packages. Its 869-file source manifest and complete log are retained. An earlier
shared-tree run failed the concurrently outdated prompt-vector inventory
expectation and preceded final tier alignment; that failure log is retained,
and the isolated passing run contains the already banked inventory correction.

A deterministic regression prices 10,000 prompt tokens at 1,000 tokens/s plus
2 s of decode as 12 s cold. Saving 4,096 tokens with 120 ms staging earns
3,976 ms credit. Adding 3,750 ms of queue/pending work yields 11,774 ms and wins;
adding 7,500 ms yields 15,524 ms and loses. A slower 500 tokens/s warm machine
also loses to the 12 s cold candidate. These are arithmetic checks, not measured
end-to-end speedups. Retained non-isolated selection benchmark samples establish
zero allocations in that helper, not a latency gain or production rollout.
