# Public long-rank selected cut proposal

2026-09-14. Outside-repository source and fake CPU work only. Root integrates
after actual cut12 serial rank qualification and source correlation complete.
No native executable, model payload, actual prompt or rank/sidecar candidate was
read or executed to construct this patch or its synthetic tests.

Add `--stage-cut 12` to the existing public `long-prefill-ranks` command. The
explicit selection initially requires `serial_v1`. Omission retains the existing
half-plan path and both existing scheduling policies; an explicit16 is not added
to this initial registered-selection table. All short commands retain their
existing behavior. Long solo, prefill-ranks and other modes do not acquire the
new selection. This is an experimental launch/source contract, not an independent
numerical or timing audit.

## Source scope

Copy the twelve files under `proposed/` to their same repository-relative paths.
Seven runtime files are replacements; `long_stage_cut.py` is new. Three test/
fixture files are new; the existing short-cut parser test changes only its name
and removes long ranks from that one parser-refusal list. Its generic short-only
helper/foreign-mode tests remain unchanged. `runtime.patch` and `tests.patch`
describe exactly these files against the saved `originals/` bytes.

The new descriptor table separates registered source metadata and policy
eligibility from geometry. Its cut12 Plan/stage/configuration fingerprints match
the pinned native metadata-only control. Geometry delegates to the unchanged
`stage_ranges.ranges`; no new Plan hashing, metadata float serialization or layer
arithmetic is introduced. Future cuts/policies require a reviewed descriptor and
eligibility update plus corresponding qualification, not another validator.

`cli.py` routes long commands to their own early gate while keeping the short
`stage_ranges.option` gate unchanged. The long parser reuses `StageCutArgument`
through its internal `add_parsers` argument, preserving duplicate refusal.
Direct long CLI/input/configuration/staging/supervisor calls validate an explicit
selection before path, input or process work. Solo contract calls also reject
an injected cut. The existing agreement and local-source loops consume selected
expectations; there is no second source-load validation implementation.

Only an explicit selection adds `stage_cut` to context, one native flag pair,
and `selected_layer_plan` to the receipt. The receipt records source identities
and explicitly keeps independent numerical/action/timing audit false. The
registered artifact/configuration pins, raw8192 input bytes/origin preservation,
512 chunks/output1, source/bundle archives, native300/parent330 bounds, absolute
zero-swap/resource screens, loopback warning and whole-cohort cleanup remain.
Profile/request/history and v4 wire semantics are unchanged. Existing phase
requests remain optional and uncollected; this patch adds no owner-trace flag.

## Checks and limits

The prospective fake suite passed109 tests: all96 existing public stage tests,
with the one parser expectation updated, plus13 new tests. The new cases cover
duplicate/foreign/unqualified selection, direct-call rejection before IO, exact
argv/default history, coherently rehashed stale Plan/configuration, typed source
layout/bytes and storage binding, selected receipt scope, fake full CLI staging,
post-run drift, stale-source cohort fencing and deadline cleanup.

The full CLI fake reuses the existing public harness and its synthetic config
pin substitution; it exercises orchestration, not actual registered source
qualification. The separate direct contract cases use the recorded descriptor
constants with synthetic prompt/outer records. No raw model outputs are invented
as numerical evidence.

Twenty-one saved-original comparisons pass: fifteen serialized native configs
(both default policies, two ranks, solo and phase omission/false/true), plus six
default context/retained-byte comparisons. They establish those default bytes,
not arbitrary full launch-receipt identity. The source check separately preserves
seventeen repository source pins and matches the descriptor to a metadata-only
native control. That private control is a development check only; integrated
public tests require no private path, download or native invocation.

Run the outtree checks with explicit paths:

```sh
python3 -B run_cpu_checks.py --repository REPOSITORY
python3 -B compare_default.py --repository REPOSITORY
python3 -B source_check.py --repository REPOSITORY --control PINNED_NATIVE_METADATA_JSON
```

Root should run the integrated public stage suite and update public command and
qualification documentation after reviewing/copying the frozen patch. No compiler
or native rebuild is needed solely for this Python change. A passing public
launcher still requires a separate matching pair/rank numerical audit before
claiming correctness, and separate sidecar retrieval/audits for local phase data.
