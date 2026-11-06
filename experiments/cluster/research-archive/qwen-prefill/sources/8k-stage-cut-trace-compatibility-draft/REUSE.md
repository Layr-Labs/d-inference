# Reuse phase and owner audits for cut12 8K ranks

Both existing auditors can be used unchanged. Their phase, timestamp, identity,
schema, and containment checks do not assume a 16/16 layer split. No production
validator or native file is changed by this compatibility assessment.

The unchanged workload has 16 chunks of 512 tokens. Rank0 still emits 204 coarse
phase events and rank1 emits 235. Each selected-owner trace still contains eight
events for frame 7, offset 3584, width 512 and frontier 4096. These are token/frame
coordinates; the owner now evaluates 12 or 20 layers within the same enclosing
callback. Marker spans remain local CPU-observed intervals including existing
checks/synchronization, not GPU operator duration.

Use the existing file APIs:

```python
phase_clock_audit.validate_ranks([stdout0, stdout1], [phase0, phase1])
owner_clock_audit.validate_ranks([stdout0, stdout1], [phase0, phase1], [owner0, owner1])
```

Or invoke each frozen script from its existing directory:

```sh
python3 -B phase_clock_audit.py ranks STDOUT0 PHASE0 STDOUT1 PHASE1
python3 -B owner_clock_audit.py ranks STDOUT0 PHASE0 OWNER0 STDOUT1 PHASE1 OWNER1
```

## Source compatibility overlay

`source-compatibility.json` pins 19 current source files byte-identical to their
frozen marker/collector/publication controls. These include the eight owner
markers, both request paths, rank sender/receiver, phase trace, fixed-frame
factory, collectors and shared output publication gate.

Eight current admission/Check/Main files separately match the reviewed selected
cut proposal. Its manifest is `426943e284b57a6c7e0d4780615659df7bf02930845c0a3b0351e0929d15dcbc`.
The earlier whole Check/Main copies pinned by the phase/owner dependencies are
historical controls. They are **not** asserted to equal current whole files.
The selected-cut overlay accounts for this admission/forwarding change; it does
not replace the fresh executable/source-archive verification performed by the
parent for the actual native binary and invocation.

`python3 -B verify_source.py` rechecks these 27 selected source files. Supply
`--source-root` pointing to the saved archive's corresponding
`Sources/ClusterInference` directory to compare the archived copies instead.
This remains a selected-file check, not a complete source archive or build proof.

The source-derived owner parent intervals remain:

| Role | Frame-7 enclosing markers |
| --- | --- |
| rank0 | `prepare.begin` → `prepare.committed` |
| rank1 | `receive.beginConsumption` → `receive.consumptionAndSelectionValidated` |

Every owner time must lie within its own role's matching phase interval. Rank1
has no main origin timer. Never align, subtract, sum, or rank the two clocks as
a shared timeline. Neither unclassified gaps nor residual time measures observer
overhead or communication cost.

## Required join to current qualification

A trace pass alone establishes neither selected Plan nor numerical correctness.
For this cohort, retain the following joins in the parent/provenance result:

1. The fresh parent must pass its native exits, whole-cohort cleanup, source,
   input, resource and sidecar retrieval checks. Bind the exact current binary,
   source archive, epoch, serial policy, `--stage-cut 12`, raw prompt and both
   opt-in trace flags. Match the 19 unchanged source pins and the selected-cut
   overlay to that archive. A source check against the live tree alone is not
   executable provenance.
2. Apply the frozen 90-test numerical rank auditor, manifest
   `ce07ec46b650a3d59d7bffd4926b8372b2e30f28fa944975f058b82fa4d3cc55`,
   to these exact stdout bytes. It requires Plan
   `8c3fef079cc82295d70851ef9d9193954afc0d008ad09ce239baaa1a51391fed`,
   348/579 tensor ownership and 27/45 final state components, then validates the
   fresh pair checkpoint and its complete independently pinned CPU result.
   Use the qualified cut12 pair raw/result hashes supplied by the parent;
   historical 16/16 reference or rank receipts cannot substitute.
3. Match each phase and owner result's input stdout SHA/byte count to the same
   ordered rank stdout in that passed numerical result and parent. Match the
   sidecar SHA/byte counts to the parent's retrieval receipt and saved files.
4. Match epoch, policy, agreement fingerprint, full recorded-request fingerprint,
   simple request fingerprint, profile fingerprint and raw/logical prompt hashes
   across numerical, coarse-phase and owner results. The recomputed agreement
   fingerprint binds Plan, both stage/config identities and source commitment
   through the strict numerical validator. Owner identity itself contains no
   model/config/plan hash. The simple request hash must not replace the full
   recorded history hash in a sidecar.

The parent can then report these as supplementary local observations for the
qualified cut12 run. Raw boundary/state values, candidate logit bytes, GPU overlap,
physical Thunderbolt transfer, measured overhead and causal speedup remain outside
these auditors' evidence. The trace availability and flags do not independently
prove successful native retirement or outer publication.

## Prospective fake checks

`test_reuse.py` supplies the frozen numerical cut12 fixture to the unchanged
auditors with synthetic phase/owner timestamps. Both serial and lookahead cases
pass their numerical and local trace checks. Wrong identity, action or parent
containment rejects. Explicit scope tests also show a coherent wrong Plan or
opaque invalid final digest may pass the trace audit while the numerical oracle
rejects: the qualification join above is required.

No upcoming rank stdout or sidecar was accessed for this assessment. A completed
parent/result summary was received during the work; it was not used to change any
helper or expectation. Fake timestamps are not measurements. Existing auditors
and frozen receipts are preserved.
