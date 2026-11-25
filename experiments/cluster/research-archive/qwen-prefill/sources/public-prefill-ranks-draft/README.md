# Optional public v3 prefill-ranks extension — review draft

This directory is an out-of-tree source overlay, not an installed launcher.
It adds only `prefill-ranks`: a fresh local ring cohort, exactly65 prompt IDs,
chunk32, output1, native precision, explicit v3 scheduling policy and logits
dtype. It does not expose SSH, a resident cohort, arbitrary batching, a larger
prompt, numerical tolerances or performance qualification.

## Review and integration

`integration.patch` contains repository-relative changes. The paired
`source-manifest.json` binds every proposed file and the current base files.
Check those base hashes before integration. No repository source, native binary,
model payload or old frozen launcher was modified to create or test this draft.
The copied `run_stage_checks.py` is unchanged and is included only for the test
assembly; the existing thin public entry already calls the extended parser.

New runtime modules:

- `prefill.py`: closed v3 agreement, ready/final and peer identity, source-load
  identity and terminal retirement checks. Native `execution` remains opaque.
- `prefill_baseline.py`: pinned recorded-baseline admission, native evidence
  fingerprint reconstruction and actual final-row dtype/hash validation.
- `prefill_resources.py`:6GiB initial actual-free screen before source/bundle
  snapshots and artifact hashing. Existing post-hash8GiB reclaimable, pressure
  and zero-new-swap policy remain in use.

The small existing-module changes are parser/orchestration routing, mode-specific
argv, retained baseline admission, and optional namespace hooks for ready/final
and immediate peer-ready agreement. Old P2P/v1 validators and argv are unchanged.
The new mode starts its swap reference before hashing. Old modes retain their
existing gate order. Native `rank_worker`, process ownership, bundle creation,
registered-artifact verification and runtime configuration are unchanged.

Baseline file SHA and native `baseline.fingerprint` are distinct mandatory pins.
The baseline must have an independent UUID but the same source, actual history
and65/32/1 schedule. Its final dtype binds the explicit CLI declaration. Source
activation dtype is independently bound to the baseline source, not inferred
from the final-logit dtype. This checks historical evidence consistency; it does
not repeat its native execution, build or artifact audit.

A successful v3 launcher run means outer agreement/completion passed. Both
`baseline_audit.performed` and `independent_numerical_action_timing_audit.performed`
remain false. The independent numerical/action/wire/timing auditor is a separate
step. No scheduling or physical-transfer performance claim follows from exit0.

## CPU verification

Use new receipt paths so historical results remain intact:

```sh
python3 run_cpu_checks.py --cluster REPOSITORY/experiments/cluster \
  --receipt NEW_CPU_RECEIPT.json
```

The runner builds a temporary source-only union of the existing package and the
draft files, then runs the dedicated tests with subprocess and socket creation
blocked. `cpu-check-final.json` records45 passing tests:23 existing stage tests
(including updated help/archive expectations) and22 additional v3 cases. An
intermediate input-fixture test failed because macOS resolves `/var` through
`/private/var`; its expected path was corrected to use the actual resolved path.
The earlier receipt is preserved. No implementation failure was hidden by that
fixture correction.

`check_saved_compatibility.py` is a separate CPU-only replay tool. It takes exact
baseline, launcher-receipt and completed-provenance-audit pins. It reads saved
configuration/prompt/JSONL metadata only. `saved-schema-compatibility.json`
records successful admission of the pinned real baseline and all8 ready/final
records from the two historical v3 policies. This establishes saved-schema
compatibility, not a new native execution of the proposed public entry or a
repeat of the independent numerical/action/timing audit.

The source manifest also records that all219 current repository source files
from the frozen v3 source manifest and the frozen private launcher files stayed
byte-identical during this task. Preserve those original receipts and counts.
