# Measured two-node placement planner — source candidate, 2026-09-20

This Foundation-only library predicts and compares adapter-supplied candidate execution graphs. It is staged privately, has no default activation, and has not been compiled or run by its author. It does not admit requests, reserve memory, load weights, establish trust, create transports, or migrate runtime state.

`MeasuredPlacementAPI.predict(Data)` accepts the versioned `PlacementEnvelope` and returns sorted-key JSON with all accepted predictions, refusals, the objective winner, and a Pareto set. Internal input/output records are in `Sources`; the public JSON facade avoids adding a product dependency or CLI now. Swift's synthesized Codable enum encoding is the v1 representation. The decoder does not reject unknown JSON fields, so this is not an authorization or closed-wire parser.

## Adapter contract and calculation

The adapter supplies the legal cuts and whole-expert ownership candidates to evaluate. Every candidate has its own source-bound recipe, independent prefill and decode placements, required per-step operator coverage, measured task graph, and memory ledgers. This core enumerates that supplied set; it does not invent legal model decompositions. Single-node, ordered pipeline cuts, replicated operators, and unequal/noncontiguous whole-expert banks use the same calculation. Unique physical weight-region IDs count tied allocations once per node; packed bank bytes come from the adapter, never an assumed model size.

Every local task requires an exact measured duration for its node, operator list, ownership, phase, step, prompt sample/shape, arithmetic profile, native builds, cost basis, and evidence identity. Link models require measured direction, latency, effective wire bandwidth, byte/record domain and fit margin. An authenticated transport also requires explicit measured seal/open rates and per-record crypto cost. A diagnostic unprotected profile cannot supply authenticated costs. Rates and latency must have disjoint measurement scopes; no pair-minus-solo or nominal-FLOP inference is used. Median/p95 component inputs produce a deterministic component-cost prediction; their sum is not a statistical request p95 or a hard deadline guarantee.

The bounded list scheduler uses two compute resources, two host resources, and one serialized link. Transfers conservatively hold the link and both hosts for latency, wire, crypto and fit-margin time. Per-operator prefill chunk order and full autoregressive decode-step serialization are enforced. The adapter graph must additionally encode legal operator dependencies, routing/gather order, all control/ACK rounds, its prepared-buffer frontier, and actual first-token delivery. The planner does not prove model arithmetic, tensor liveness, or the authenticity of evidence from a supplied hash. The caller must bind those adapter/measurement receipts before using a prediction.

`firstTokenNanoseconds` is the complete prefill graph makespan. Decode covers the remaining `outputTokens - 1` steps; transition cost is reported separately and included in total request time. The three objectives rank first-token, steady decode, or total request latency explicitly. This is a resident-request estimate: cold initial model loading is outside the default scope and must be explicitly modeled and measured by an adapter before making a cold-start claim.

A changed decode placement requires a measured transition graph. Exact newly needed weight IDs need real load measurements. The adapter declares actual KV payload in each direction, and the graph must contain at least that transfer volume; it must not label control bytes as KV. The transition charges the union of both weight layouts and both phase KV allowances, plus its host/native staging, activations, workspace and other retained allocations. No runtime handoff is implemented and no zero-cost migration is assumed. If the adapter cannot establish a state-transfer recipe and peak liveness, that candidate must remain absent/unmeasured.

## Memory and evidence limits

The two observations bind the exact node IDs, evidence, age, AC state, pressure and swap. Admission is `actualAvailableBytes >= physicalWeightBytes + six disjoint live categories + minimumFreeBytes + guardBytes` at every phase. The observation must be from the declared pre-candidate baseline, with candidate allocations excluded; a post-load free reading cannot be combined with another full-weight charge and interpreted as the same baseline. A runtime must re-observe and enforce its original resource and ownership gates at actual admission.

All bytes are integer bytes, rates are bytes/second, and durations are integer nanoseconds with checked arithmetic and upward rounding. Decimal GB and binary GiB are not interchangeable. No physical-RAM-only fit claim exists. The reported 2026-09-20 Gemma P4096/C64/cut8 refusal (6,848,708,608 B actual free versus 6,866,186,254 B required) remains a failed resource gate; it is not calibration supplied to this planner and does not reduce any floor. There are no measured whole-model EP or link/encryption calibrations in this package.

Bounds: 16 MiB JSON input; 64 candidates; 4,096 operators and phase tasks; 32,768 total tasks; 8,192 calibration entries; 64 ready tasks/dependencies; transfer payload up to 256 MiB and 1,024 records; 32 MiB output. Wider recipes are refused. The scheduling heuristic is deterministic, not a globally optimal arbitrary-DAG solver.

## Qualification and next integration

Nineteen Foundation groups are staged in `Tests`. All numbers are fabricated fixtures: one two-stage graph gives 56 ns prefill and 72 ns for two serialized decode steps. A separate measured synthetic migration takes 58 ns and reduces decode to 42 ns; total-request and decode objectives therefore choose different plans. These are calculation controls, not model performance results. Other controls cover ownership, calibration substitution, crypto charges, memory/resource gates, graph errors, overflow and the JSON boundary.

After root grants a compiler slot, run from this directory with regular root-owned stdout/stderr files:

```sh
python3 -B check_sources.py
python3 -B run_cpu.py --output qualification-1 > root-cpu.stdout 2> root-cpu.stderr
```

The root-owned controller performs one Swift 6 warnings-as-errors compile (`-j 2`, 60 s) into a fresh local ModuleCache and one CPU fixture child (30 s). It reuses the exact reviewed owned-child helpers, records natural exit/reaping/group absence, caps diagnostics at 4 MiB and compiler output files at 512 MiB, verifies exact 19 completions, and rechecks all source pins. No retries, native model code, GPU, network, or existing cache/workspace mutation occurs. The library-only `Package.swift` is provided for later integration; this qualification compiles the same sources directly with the bounded controls.

Next: an adapter should export an exact observed resident graph, actual per-rank stage/operator intervals, separately measured link/crypto components, and the complete simultaneous-live ledgers for one qualified workload. Refused/unmeasured candidates remain visible. Compare predictions with a later held-out measured cohort before any scheduling activation. No product wire, capability, saved configuration, signing or trust policy changes are included.

Applicable repository instructions are pinned in `context.json`: keep responsibilities modular, preserve trust/resource/lifecycle gates, and run meaningful checks when scheduled. MAIN, the master worktree, prior qualification evidence, and every frozen experiment remain untouched.
