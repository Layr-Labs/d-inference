# Cluster protected runtime software and TLS qualification

> Last updated: 2026-09-17 · commit `605651bb9`

The private protected-cluster candidates pass the selected coordinator, Provider,
native runtime and actual loopback TLS checks below. This records software
qualification and exact unsigned artifacts; encrypted two-Mac inference, device
trust, performance and serving readiness remain unqualified by these results.

| Qualified component | Retained result |
| --- | --- |
| Coordinator, default build | 51 focused methods pass with the race detector; command package has seven passes and one explicit skip |
| Coordinator, private build | 54 focused methods pass with the race detector; command package has ten passes and one explicit skip |
| Provider | 117 selected tests in 19 suites pass, including both real WebSocket member-acknowledgment cases; matching CLI build passes |
| Numerical native runtime | 38 XCTest and seven Swift Testing methods pass; worker suite passes 19 methods |
| Native capability | Four accepted and 13 rejected input/producer controls, plus five actual command-child cases, pass |
| Private TLS verifier | All six actual loopback TLS/URL cases pass |

Both coordinator command runs skip only
`TestMaintenanceProcessDoesNotServeOrSeedAdmin`, with the exact recorded reason
`DATABASE_URL not set`. Database maintenance behavior remains untested. Separate
default and `native_pair_hardware_experiment` binaries build successfully; the
default excludes the private driver, and the private `trust_only` mode retains
a nil native approval catalog and creates no pair selector. These focused checks
do not constitute a new complete coordinator-suite run. The qualifying build/test
controllers exit successfully, are reaped and leave no owned groups; their source
checks pass before and after execution.

The owner endpoint correction drains the actual pipe to EOF instead of treating
`process.isRunning == false` after a terminal frame as EOF. A deterministic
actual-owner fixture reproduces loss of a buffered release acknowledgment on the
old endpoint. The corrected endpoint accepts the valid original acknowledgment;
missing and wrong acknowledgments, and an abnormal owner exit even with an
acknowledgment, still refuse release. All four cases pass. The earlier Provider
failure alone was insufficient to attribute the bug; the old/new fixture supplies
that evidence. Existing retirement and late-diagnostic checks remain in the
matching helper qualification.

Numerical export initially failed Swift object compilation because its publisher
invocation captured a borrowed live checker. The corrected
`QwenProtectedEvidenceExport` invokes the publisher synchronously inside
`withoutActuallyEscaping(publisher)`. Both public nonescaping signatures, the
borrowed checker and before/after live checks remain; no publisher is retained or
queued. The qualified runtime includes charged capture, cancellation during
encoding, retirement and held-capacity cases. Earlier failed builds remain
retained. Passing these fixtures does not supply an actual protected-model row
or state comparison.

The unchanged application-scoped TLS verifier uses Security.framework trust
evaluation with the original policies, the configured hostname and the pinned
CA. The valid fixture completes TLS 1.3 and one WebSocket upgrade. Expired,
untrusted, wrong-anchor and wrong-host certificates are refused; a wrong URL is
refused before connecting. The final fixture correction accepts the legitimate
`Upgrade: WebSocket` spelling and does not change the verifier. No system trust
store changes occur. This validates the local verifier against test certificates,
not a deployed coordinator, device attestation or RDMA record delivery.

The [compact evidence](evidence/cluster-protected-runtime-qualification-20260917/qualification.json)
joins the actual Provider CLI `8bb652d7…cdf7c786` to its unchanged 13,859-file
candidate and the numerical native `3d9c016f…27822c39` to 3,081 source and 9,832
dependency entries. The native package contains the actual capability
`8dea283e…aa08723`, protected description `7153b9cf…67df2db` and resource policy
`dc910813…052db5`. That policy charges 196,788,480 additional bytes, including the
10 MiB numerical-evidence host allowance; it is not a measured whole-process
peak. The private scope remains Qwen9B, cut16, serial, 32 prompt tokens, chunk16,
two output tokens and empty stop IDs. The descriptor keeps serving disabled.

The evidence includes complete artifact/resource hashes from the successful
build/package receipts. This report only rereads small metadata and retained
results; it does not rehash large binaries or run tests. “Unsigned” denotes no
release-signing qualification, without making a claim about incidental ad-hoc
Mach-O signatures. Authorized signing of the exact Provider composition, genuine
APNs/code proof, current SE/MDA evidence for both Macs, and matching private
coordinator/release configuration remain pending. Their bindings remain null;
no signing, installation, deployment or production trust gate is changed here.

The [delivery plan](../design/distributed-cluster-delivery.md) tracks the remaining
integration. [Earlier authorization and allocation checks](2026-09-16-cluster-authorization-and-buffer-checks.md)
and [record encryption CPU cost](2026-09-15-cluster-record-encryption-cost.md)
retain their separate scopes; these software results add no performance claim.
