# Registered Qwen9B MTP proposal and owner release

> Last updated: 2026-09-15 · commit `605651bb9`

A two-Mac registered Qwen3.5 9B probe produced a real MTP proposal and completed
both authenticated worker-release handshakes after an owner shutdown correction.
The proposal was not accepted or consumed. This qualifies the bounded proposal
and cleanup path, not speculative generation or a performance improvement.

## Actual request and result

The 24 GB and 48 GB M4 Pro Macs ran the same registered 4-bit target over
Thunderbolt RDMA, with layers 0–3 / 4–31, 32 prompt tokens, 16-token chunks,
two greedy target outputs, empty stop IDs and fresh request state. The assistant
ran on the final stage using the registered inline MTP weights. Native worker
SHA256 was unchanged from the earlier failed probe:
`34fcd255f3bab741586476867da26035cfd0ee0f2ba6ee708551c07d0bdbcba1`.

| Observation | Result |
|---|---|
| Ordinary target token IDs, matching both ranks | `[2018, 6165]` |
| Assistant seed / proposed token | `2018` / `6165` |
| Assistant history | 31 → 32 |
| Proposal accepted / consumed | false / false |
| Completed frames / committed frontier | 3 / 33 |
| Native cleanup observed | true on both ranks |
| Authenticated owner lease release observed | true on both ranks |
| Controller exit / alias restoration | 0 / restored |
| Separate final process and journal observation | no workers; both journals empty |

The frozen prospective validator passed against the actual returned sidecars and
controller records. It checks proposal/history/request consistency and cleanup
claims; it accepts either a matching or mismatching draft token. It does not
independently establish target-model numerical correctness. Target execution
still records MTP disabled because the proposal never changes committed output.
No throughput or external TTFT claim follows from this two-token request.

## Failure, recovery and correction

The preceding physical probe produced the same target and proposal tokens and
observed native cleanup, but neither owner acknowledged lease release. Both
333-byte canonical ownership records remained unresolved. That result remains
failed.

An actual CPU owner/worker reproduction exposed a matching shutdown race. The
single-request worker retires and becomes unavailable; the owner begins fencing
it while a valid controller shutdown is still in transit. The former
`ClusterWorkerOwnerService` throws when that shutdown arrives after native
terminal observation, leaving the release-reading loop.

The correction consumes a valid shutdown as a drain request when the owner is
already fencing or has observed native terminal. It preserves session, sequence,
request-phase and delivery checks. It forwards no command into the closed child
and manufactures no shutdown-complete event. Journal resolution still requires
actual native cleanup, released request resources and the current connection's
explicit release request. Six focused CPU cases and the existing 13 SSH control
groups passed before the fresh physical run.

The two known stale records were recovered separately before the rerun. Recovery
required their exact failed-run identities, current process absence, exclusive
locking and durable backups, then cleared the same owned file descriptors and
verified empty readback. It supplied no protocol ACK and did not change the prior
failure. The successful rerun used a fresh membership epoch and request UUID,
with one coherent rebuilt owner/controller and four matching control libraries.

## Resources and retained evidence

All 29 samples per rank passed raw free-page arithmetic replay, AC power,
zero reported swap, pressure level 1 and the six-GiB actual-free guard. Minimum
observed free memory was 9,723,920,384 bytes on the 24 GB member and
15,881,601,024 bytes on the 48 GB member. These are sampled observations.

Private evidence is retained under
`/Users/developer/DarkbloomDev/cluster-research/qwen-resident-mtp-probe-clean-rerun-20260915/physical-1/`.
`root-review.json` joins the exact sidecars, successful controller result,
independent raw-resource replay and separate process/journal observations.
The comparison SHA256 is
`5939bcc0f7c27fc1adfc2de723b220ac4a64b29ac84431f00ce04ff1c8e1f72d`.
The frozen source package SHA256 is
`8364e34b5d5bccab1ddcfa170ef730c60776b874287f2fd2b387c43257fb3c54`.

The [execution plan](../design/distributed-cluster-execution-plan.md) still
requires target verification, accepted-prefix publication, rollback, EOS and
cancellation during speculation, followed by matched MTP off/on measurements.
The earlier [tiny GPU capture/history check](2026-09-15-cluster-mtp-tiny-forward.md)
remains a separate numerical test. This result does not qualify 27B, Gemma,
representative SLA compliance or a distributed release.
