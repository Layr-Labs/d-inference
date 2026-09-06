# Two-host connected cache fixture: source integration

> Last updated: 2026-09-06 · commit `7f07ab618`

The connected HTTP fixture now accepts two explicit provider hosts through the
existing loopback relay. The source passes 29 Go functions with race detection
and 18 Python functions. No real two-host provider or model run occurred in this
milestone, so it establishes no cross-machine latency or capacity improvement.

## Implemented scope

`SuiteConfig.ProviderTargets` binds each fixture account to a declared host;
registration order does not identify the donor or cache holder. The local and
owned-host adapters share `ProviderStartSpec`. The owned SSH adapter uses a
loopback reverse tunnel, bounded private stdin, correlated control responses,
and one owned provider process group. The normal nil-target launcher remains
available. Production listeners and routing policy are unchanged.

The initial explicit-host scope retains the existing donor, repeat, tenant,
continuation-on-B and original-after-continuation cases. Runtime/model/assistant
bytes are pinned before launch, and the existing encryption, capability,
backend, memory, actual-hit and request-retirement checks remain in force.
The [owned-host reference](../../e2e/testbed/OWNED_HOSTS.md) describes the typed
input and lifecycle; [developer instructions](../developer/test.md#connected-coordinatorprovider-http-cache-gate)
link it from the existing connected gate.

## Actual validation

| Executed validation | Result |
| --- | --- |
| Go testbed and connected helpers with `-race` | 29 functions; 54 including subtests; pass, no skips |
| Python filesystem, host-observation and harmless-child fixtures | 18 functions; pass |
| Source3 complete-runtime binding regression with `-race` | 1 function; 12 including subtests; pass |
| Source correspondence onto `7f07ab618` | All 17 paths match source1 plus source2/source3; no source merge changes |

Planted tests cover runtime/assistant/catalog substitution, path escape, bounded
HF blob symlinks, SSH quoting, missing-then-ready state, cancelled-request late
responses, account-to-host binding, and independent entry/cleanup predicates.
Stop, EOF, HUP/TERM, lease and deadline fixtures reap harmless children. A leader
that exits while its sleeper remains in the owned group cannot leave that group
behind. Cleanup exceptions retain an incomplete terminal receipt.

The original descendant-cleanup test exposed Darwin's transient EPERM response
for an unreaped zombie group; its traceback is retained. The corrected helper
reaps the direct child before probing and treats EPERM as present. Final review
also found executable paths with spaces could be truncated by process parsing.
Source2 changes only that Python split and adds an injected observation test;
its 18-function Python run is actual, while unchanged Go race results are
explicitly carried from source1. Source3 additionally requires the two complete
runtime file maps to match, including bundle resources such as
`pagedattention.metal`. Planted different hashes, sizes, modes and a missing
resource are refused; the changed Go function and its 11 subtests pass with race
detection. Unchanged Python results carry from source2.

Before each next measured request, both hosts must satisfy the existing cooled
entry limits and report idle model slots. Post-run cleanup checks terminal owned
processes and leftovers, while retaining the observed temperature. A hot host
after successful work is not itself a correctness failure. Frozen HTTP6 results
are not rewritten by this lifecycle correction.

## Evidence and remaining work

The [manifest](evidence/two-host-connected-fixture-2026-09-06/manifest.json) and
[archive](evidence/two-host-connected-fixture-2026-09-06/payloads.tar.gz) preserve
58 source, diff, review and validation payloads, including immutable source1
and its small source2/source3 successors. No unchanged runtime or model weights are
copied. Manifest SHA-256: `a5edebbad46b6d058849eb04a4d63d5bd3b8ed88906d628162ddf5e943727ccd`.
Archive SHA-256: `e8a1b2bf1496e68f8494d407af58ce39319eea43ad88cc8fbb9b0038d49a1457`.

Source1 was tested from `bd8dee802`; the reviewed integration was prepared at
`bc1819129` and copied unchanged onto `7f07ab618`, retaining native `a317dde5`
and the newer Gemma QAT MTP-off records. Copying those exact testbed bytes is not
reported as another test execution. No Swift/GPU, remote, signing, key, model or
production operation occurred. Actual execution needs separately reviewed host,
runtime and model inventories plus fresh owned roots. The test-only trust
posture and ephemeral SSD keys do not establish attestation or persistent
restart durability. TTL, capacity eviction, reconnect workloads and the other
same-host extensions remain outside this first five-case two-host scope.
