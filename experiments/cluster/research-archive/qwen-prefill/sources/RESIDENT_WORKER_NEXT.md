# Resident benchmark worker: current handoff

Status from retained records, 2026-09-15 UTC. The isolated worker builds and its
CPU/control checks pass. Ten real-content development inputs are ready. This
prototype has not completed a real-model resident cohort or established
two-machine performance; 800 TPS acceptance and 1000 TPS stretch remain
unqualified.

The isolated harness is
`resident-benchmark-worker-build-20260914/workspace/experiments/cluster/inference`.
[Build 3](resident-benchmark-worker-build-20260914/records/build-3.json) passed
in 100.157 seconds, producing native SHA
`aa7d205de4d2b5b7ac26842e0fd0fa42c96774b5ed1b229f418d726636da279a`.
Earlier failed attempts remain recorded: relocated module cache/dependency
resolution, then a fixture-only missing `try`. The successful build restores
the original dependency pins. The
[preservation record](resident-benchmark-worker-build-20260914/records/original-source-build-preservation.json)
confirms the original 403 source members and native c079 are unchanged; the
isolated source snapshot contains 422 members.

The compiled `--mode qwen-resident-benchmark-worker-check` exited 0 in 0.812
seconds with empty stderr and five CPU records:

| Check | Accepted | Rejected | Additional checks |
| --- | ---: | ---: | --- |
| Open/run/shutdown protocol | 7 | 76 | Exact four declared requests |
| Controller/publication | 2 | 37 | No eager execution or write after poison |
| Resident step callbacks | 2 | 9 | Seven interruption cases |
| Solo retained admission | 3 | 23 | Actual Options/registered constructors |
| Worker CLI/admission | 12 | 67 | Fixed geometry, identities and retained reads |

See [CPU receipt](resident-benchmark-worker-build-20260914/records/native-cpu-check.json)
and [five output records](resident-benchmark-worker-build-20260914/records/native-cpu-check.stdout.jsonl).
The separate [entry checks](resident-benchmark-worker-build-20260914/entry-check/execution.json)
also retain EOF, truncated/wrong-open, actual resource refusal and fixed-deadline
termination, with no model weights present. These do not prove successful
loading or resident request execution.

The implemented control path is open → loaded-ready → four individually
permitted requests/results → actual model release → shutdown/stopped. Initial
scope is registered 9B, 8192/512/B1/output1, one warmup plus three measured
requests, solo or two loopback ranks. Existing request loops and resource
requirements remain authoritative; the entry adds AC/power/thermal checks and
one unextended cohort deadline. This does not admit 27B, M3 Ultra, or physical
distributed execution.

[Development inputs](prefill-development-inputs-20260914/prompt-rows.json)
now contain ten distinct exact 8192-ID files, each below 64 KiB. Their 68 disjoint
upstream source files and MIT notices remain retained. The pinned tokenizer has
248044 base/248077 total entries; native ID capacity remains 248320. Old
diagnostic IDs reproduced byte-exactly. See the
[tokenization handoff](resident-benchmark-worker-build-20260914/development-input-tokenization-handoff/HANDOFF.md)
and [receipt](prefill-development-inputs-20260914/tokenization.json). These are
development inputs, not a representative or qualification workload.

The private [adapter V3](resident-benchmark-worker-adapter-v3/README.md) now corrects the V2 group-cleanup gap: an unresolved process-group signal prevents closure and watchdog cancellation even when the leader has exited. The original 19 fake-process tests passed once, and three corrected tests with actual Python descendants passed under Python 3.9. The first fixture's failed observation and frozen V1/V2 remain retained. [Root pin/source review](resident-adapter-v3-root-review-20260915.json) rehashed all 19 V3 members and reviewed the runtime delta. An accepted SIGKILL is a group fence, not independent proof of descendant reaping.

The earlier [V2 Python 3.9 handoff](resident-benchmark-worker-build-20260914/adapter-v2-cleanup-python39-1/handoff.json) records the public-coordinator integration: complete 20-cohort/80-request execution, first-warmup refusal and final-close failure. All 61 fake leaders were reaped and 183 streams rehashed. Those integration runs used V2; V3 has not repeated the full coordinator fixture or run real native models. Actual identity/numerical validators remain to be supplied.

The [returned-peer snapshot](peer-return-readiness-20260915-025224.json) shows
both peers reachable again; retained hardware inventories identify M4 Pro
machines with 24 GB and 48 GB. The separate
[24 GB](returned-darkbloom-24-rdma-20260915.txt) and
[48 GB](returned-darkbloom-48-rdma-20260915.txt) records report active Thunderbolt
RDMA ports; hardware inventory reports an 80 Gb/s connected link. Those are
inventory/status observations, not measured link service or model throughput.
Root confirmed AC and completed the preserved-c079 tiny numerical check. The following real 9B short check was refused by its native memory gate with clean retirement; [current short-check handoff](SHORT_PARITY_NEXT.md) records the evidence and larger-peer preparation needed. The older
readiness command also retained an `ifconfig` path error, so its exit status
must not be read as a complete network qualification.

The preserved-c079 9B prerequisite now passes on the 48 GB peer: original guarded parent, independent numerical replay, and execution-binding audit. A separate two-Mac CPU-buffer RDMA smoke also passes, with the temporary interface alias removed and management/bridge state preserved. [Current short-check handoff](SHORT_PARITY_NEXT.md) gives the exact run locations and limits. These results do not execute the new aa7d resident owner or establish GPU-inclusive/model transfer or throughput.

Remaining work is concrete:

1. Integrate the reviewed V3 group-fencing correction with the native adapter;
   preserve unresolved cleanup as failure and qualify it on the real path.
2. Bind the adapter to the approved native/source/bundle, actual resource and
   power checks, and independent per-request numerical/timing validators.
3. Qualify one resident solo and one loopback-rank cohort with fresh state, one weight load,
   explicit permissions, retirement and failure cleanup.
4. Wire the ten development rows into the paired-study coordinator. Keep
   physical two-machine transport admission, the separate qualification suite,
   and goal aggregation contingent on their own successful evidence.

This note records status only; it does not authorize a launch or replace the
existing native, resource, source or numerical gates.
