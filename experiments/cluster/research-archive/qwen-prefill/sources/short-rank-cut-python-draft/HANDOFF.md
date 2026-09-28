# Short-rank explicit cut proposal

Source and fabricated CPU validation only. The public `run_stage_checks.py ranks`
parser gains optional `--stage-cut LAYER`. Omission retains the original equal
split; this flag is absent from p2p, prefill-ranks and both long-prefill parsers.
No current command, profile, wire schema or resource cap changes.

The matching native proposal is `stage-rank-cut-option-draft`, manifest
`13a3af889e101dc464e43ad22e314be80da8d19bc745668ec9db96a20daa3c67`.
Root must integrate that native mode admission before attempting the new public
flag with a built binary. This Python proposal does not qualify a public entry
execution or a new numerical result.

## Integration surface

Apply `runtime.patch` for the six replacements, then copy the four additions at
the exact intended repository paths in `manifest.json`:

- Replacements: `runtime/stage_checks/cli.py`, `inputs.py`, `configuration.py`,
  `ranks.py`, `evidence.py` and `storage.py` under `experiments/cluster`.
- Additions: `runtime/stage_checks/stage_ranges.py`, `stage_cut_test_support.py`,
  `test_stage_checks_cut.py` and `test_stage_checks_cut_flow.py` under the same root.

The proposal contains a saved 63-file original Python/test snapshot and a full
shadow tree for pure tests. Only the ten explicitly listed files are intended
for integration. No historical source, test, launcher or evidence was edited.

`stage_ranges.option` checks the original command and a strict integer 1..127.
`stage_ranges.ranges` implements only Plan's range constraints: two contiguous
ranges cover the source, the second starts at the selected cut, each range has
at least one attention interval, and both starts are interval-aligned. The final
model end need not be interval-aligned. Thus 32 layers/cut12 yields 12+20, and 11
layers/cut4 yields 4+7. Default 11 layers remains rejected; default 32 remains 16+16.
No cut is clamped or silently normalized. The native Plan still admits the full
configuration/topology and produces the actual fingerprints.

The context records `stage_cut` only when explicit. The request fingerprint is
unchanged because request history is unchanged; source/plan/stage fingerprints
continue to come from native receipts. Each generated rank config appends one
`--stage-cut` pair only for short ranks. The CLI rejects duplicate cut flags.
Programmatic foreign-command cuts fail before input IO or native configuration.

Captured source ranges, recurrent/KV state ownership and active parameter mapping
all use the same derived interval. Compact parameter indices subtract that
stage's source start. Global state names stay global. Existing peer/source/
storage commitments, baseline plan/history checks, native row-byte reconstruction
and retirement requirements are retained. `evidence.state_entries` adds an
optional last argument defaulting to None; existing prefill callers retain halves.

No production Python code manufactures a Plan or construction-configuration hash.
Without a pinned baseline, native peer/source/hash consistency remains the
existing qualification; it is not an independent reconstruction of the native
Plan or checkpoint descriptor payload. The inherited storage summary keeps
`source_descriptor_payloads_rederived=false`. Synthetic test hash tokens are
explicitly labeled invented and are never used as real model expectations.

## Validation

From `proposed/experiments/cluster`:

```sh
python3 -B -m unittest test_stage_checks_cut test_stage_checks_cut_flow
python3 -B -m unittest discover -p 'test_stage_checks*.py'
```

Results: 15 new fake tests pass; all 81 retained stage tests also pass (96 total).
Tests patch subprocess and socket entry points to fail, use generated metadata
and arrays only, and never open a model payload or candidate result. They cover
12/20 and odd4/7 ownership, explicit-half compatibility, stale half output,
request/plan/header/storage/state mutations, matching versus stale pinned
baseline evidence, original-command guards and whole-cohort fencing/reaping.
The minimal invented storage fixture tests the existing parent consistency
contract; it does not claim to be a loadable Qwen checkpoint.

Run `python3 -B check_default_compatibility.py` from this draft for the separate
17-check comparison against saved original Python. Default retained context,
both native configurations, state totals/hashes at six frontiers per rank, and
pair/storage summary bytes match exactly on the same fabricated fixture. This
is a source compatibility replay, not a native or saved-candidate replay.

The first focused test run exposed only a fixture assertion that compared macOS
`/var` with the native-resolved `/private/var` temporary path. The corrected test
compares resolved paths; the original failure log remains. No production logic
was changed to address that fixture issue.

Pipeline's independent source review found no blocker in the seven runtime
files and focused tests. Review did not execute tests or access candidates.
Full same-binary native and public-entry qualification remains root-owned.
