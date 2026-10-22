# Prefill planner handoff

Public code: d-inference/experiments/cluster/planning. The model-agnostic CPU
planner evaluates explicit serial/lookahead per-chunk cost scenarios. It keeps
unknown costs and memory visible, excludes incomplete candidates from ranking,
and never grants native admission. See its README for the reduced credit
fork/join model and its startup/ACK caveats.

The public planning.measurements adapter now replaces the fixed private phase
extractor for registered9B long-rank observations. A portable pinned packet
contains prompt, two ready/final JSONLs, two traces and externally asserted
provenance. Fresh outer/phase replay retains independent clocks and exact
workload/artifact/plan/stage identities; numerical/runtime/hardware audits are
not replayed by this converter. Optional null/absent active inventories are
missing evidence; reported mappings and opaque hashes never prove descriptors.

Native metadata export is implemented at
inference/Tools/LayerStageCandidates; it calls actual native Candidates/Plan,
checks pinned bounded regular-file inputs and emits complete32MiB-capped JSON.
It does not construct MLX models or change runtime admission. The public14-source
Swift6 fixture passed23accepted/39rejected, receipt9ae0037f23401319b6a25127cd11e60e2891969f6df7a44c0d80c1b81ab62de8.
Root reviewed/compiled; a separate peer exporter review was unavailable.

The --catalog/--catalog-sha256 CLI imports that DTO with closed consistency
checks and exact source/Plan/stage/construction identities. Every present
reported active mapping must match; incomplete ownership stays unknown and
contradictory partial evidence refuses. Only the observed cut gets an association;
other cuts remain unmeasured. The public independent-device projection is a
separate explicit assumed output, with all target overhead and memory null.

Root native export replay produced7retained9B and15retained27B candidates.
Both actual saved9B cohorts (16/16 and12/20) joined927active mappings each.
All64primary services plus32local pre-header cells exactly matched the frozen
vectors. Receipt runs/native-prefill-catalog-replay-20260914/execution.json
ab42e13f6c296e247d56def63d9a0ddfa6904e8b0a16b278597074aee6ead205.
Public services at runs/public-prefill-measurements-replay-v2-20260914:
balanced23a3f1e12fec98037a33bea64b47c5fc2348a0609e40f00d64af8a356e285b7f,
cut12a92f5fe86bed1e2d3d7890f6505de82c7525ea771140e3b5a35107c7b49678cd.
These are differently instrumented same-GPU serial runs, not a controlled cut
comparison or measured independent-device performance. Their separately assumed
zero-overhead9B scenarios remain10,005,707,250ns and12,091,115,957ns; no fullTTFT,
TPS or ranking because overhead and target memory remain unknown.

Final41Python testsPASS;22files parse asPython3.9. All four saved public services/
association outputs are byte-identical after the final CLI fix. Receipt
runs/public-prefill-adapter-final-20260914/execution.json
89b45e39138895b5757794e226794c8277408b261b07bae4e836cf5ac41e3bda.
Independent final association source review6f343e9cc77361ca4557152572c08f5d101d4e33d3f8215f5394a53149fd508c
has no blocker. Phase source review8d36749fdf050af0e9b308b00b72eb63f5bbd3845391e876e136556e4aab2198.
Docs-check280PASS; public scan595files/587links
b6be64f73dbf9879187bb2f01a25d5921bd7d27dd803c963d657d43b85f04a1b.

Next: obtain target-device services, memory peaks and actual physical handoff
costs before ranking deployable plans. Native qualification remains in
SHORT_PARITY_NEXT.md. A bounded source review of27B M3/portable arithmetic is
underway; preserve the distinction between production M5/NAX eligibility and
experimental actual-device arithmetic before proposing any new profile.
SelectiveTP, MoE and decode require separate graphs/adapters; not modeled here.

At18:01:25UTC peer48 stillSSHtimeout, peer24 online12%discharging. No native model
job is live. Nativec079 and403-source runtime bundle are unchanged. No new peer
installation. Goal remains active; M3/27B performance and release are unfinished.


The next bounded software increment is frozen in qwen27-portable-arithmetic-profile-draft/PROPOSAL.md (manifest26188e51059890c4079e7d5b62b7f44a48089a2ee077e71c82d94d0ccd805229; note c957aab05a84a938d893ddbed15534fa0f93f67fd2ed19bf483623b592bc62ed). Root read it and verified all3members/53source-metadata pins; review receipt 6455b1a69ea13ee60a494cddc5d92edced0b778293c37a47f61173e209427fe8. Four referenced Metal dispatch sources are byte-identical to current Cmlx mirrors. This establishes inspected source consistency, not the loaded kernels or current hardware routes.

Production exact IDs have explicit M5/NAX eligibility. Experimental registered27B already uses actual-device Metal selection under the existing query128/BF16/TF32=1 contract and keeps provider eligibility false. TF32=0 is not a BF16 NAX-off switch; absent GPU_ARCH must remain absent. No new operator/weight rewrite is justified solely by that provider policy. Proposed first change is an out-of-tree CPU short-execution evidence audit: reuse frozen numerical oracle/parent contracts; validate existing full/pair runtime DTOs; join runtime PID/path/OS/architecture/limits to completed parent, raw stdout, native/source/bundle/metallib and inherited environment pins. Emit separately keyed experimental evidence while preserving unknown NAX status and independent hardware/source/load proof limits. Current diagnostic false can mean snapshot failure and must not become non-NAX attestation. No duplicate native runtime DTO or c079 rebuild is needed. Exact future input locations and APIs are in input-locations.json; no actual short native output exists. This proposal is now implemented in the private short-execution-binding-draft package; M3/27B parity/performance remain unqualified. See the current checkpoint below.

Additional source comparison confirms all396 previously scanned public inference/Sources and runtime files unchanged since the planner baseline; receipt ebc35e8ca7d5a165340786826c0fd85cc382c7fba19506153c6e3d65353fa7ca. This count is that scanner subset, not the complete403-source native bundle. No process job remains live; goal active.


## 2026-09-14 short execution binding completed

Implemented and froze `short-execution-binding-draft` as a private CPU tool.
Manifest: `a3f427d6b3eb810fa20ece09dab78479cb24fb31430c8a00a8c9f4ad5185cd6d`
(25 members). The README defines the portable explicit-input packet and command;
VALIDATION.md records source review and execution receipts.

The checker joins completed parent, original stdout/stderr/tokens, registered
metadata, two runtime DTOs, and retained source/bundle/private member bytes. It
replays the unchanged numerical oracle and requires equality with the complete
saved numerical receipt. Profile identity is separate from request evidence.
Pinned oracle snapshots execute from owned copies; archived launchers never run.
Returned dictionaries are detached from the shared policy and oracle pins.

All 51 CPU tests pass on Python 3.14 and 3.9.6. Four actual Python CLI executions
using fabricated 9B/27B fresh/reused evidence also pass; their outputs remain
byte-identical after the return-isolation fix. Final execution receipt:
`runs/short-execution-binding-final-20260914/execution.json`, SHA
`bf7475eb8c112a1518a355fe1c7092f47fd12e73b996eaa232e9932f22c4d720`.
Python 3.9 receipt SHA:
`14497bfc0f679cf2820f2cddd2c72aca1c3372fbec4b6c5844131a73c2c04393`.
The first test-only macOS path-alias assertion failure remains preserved;
no runtime change was needed for it.

No actual c079 short-parity result exists yet. Historical execution, full
process environment, source-to-binary/loaded-Metal correspondence, NAX,
hardware identity, physical inference and TPS are explicitly unqualified.
All 403 current native/runtime source members still match the installed archive
(receipt SHA `5e64d522fe54992f66bce714a5ebe0044418359840266f56c4fe75e7b6a6e087`).

Read-only check at 18:27:59 UTC: peer24 online at 11% battery, discharging;
peer48 SSH still times out. Local machine is on AC but has 13,456.94 MiB reported
swap and insufficient actual-free memory for the existing model gate. Receipt
`peer-power-connectivity-20260914-182759.json`, SHA
`af1fb00daf988cc19b83998ceef1be98a245b34f60f103d857218eb4baabc33f`.
No native test, purge, reboot or network configuration was attempted.


## 2026-09-14 paired benchmark coordinator implemented

Implemented the public `experiments/cluster/benchmarking` module: twenty
four-request cohorts covering ten prompt pins and matched solo/distributed
conditions; five AB and five BA orders; one excluded warmup plus three measured
requests per cohort. The injected adapter owns native admission/timing/state
and process cleanup. Any request, measurement, entry, close, logging or operator
failure aborts without retry or replacement and preserves remaining skipped cells.

Exact Fraction-based aggregation computes the median of the ten per-prompt
TPS medians, with raw samples, per-prompt paired speedups and nearest-rank p95
latency. Incomplete studies cannot produce condition aggregates or target flags.
Runtime admission and performance qualification remain false. All 35 CPU tests
pass on Python 3.14 and 3.9.6; source-pinned execution record
`runs/paired-prefill-study-cpu-20260914/execution.json` SHA
`12f0f841f8a547fc5fdd7b5907dafeed0b95942ddd73c220cf377571ec31e325`.
The three retained execution examples are explicitly fabricated.

Refactor/source review kept the specification, statistics and orchestration
separate and fixed exception formatting without losing failure records. Public
README/developer test navigation updated; content scan passes 603 files and 591
links, SHA `0dd8efbd5e21b77d52a48761490aa6cff10ab6a8584a4f5ef9571fb209466c9b`.
Actual resident adapters and ten representative pinned qualification workloads
remain missing; exact next steps are in `BENCHMARK_STUDY_NEXT.md`. Existing native
and runtime files were not modified for this feature.

At 18:47:26 UTC peer24 remained online but at 10% battery, discharging; peer48
SSH timed out. Receipt SHA
`96c172fa5a141387e839f7b2a7f07c8eaa54b862806b2f7e46d6ae25f877ae32`.
No native retry, purge, reboot, network configuration or peer installation.
The broader distributed inference goal remains active.
