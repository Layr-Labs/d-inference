# Explicit cut for the short serialized rank check

Source-only proposal, 2026-09-14. Nothing in the repository was edited by this
draft. No Swift compiler, model, native process, collective, or SSH call ran.

Apply `runtime.patch` to its eight pinned bases, and copy the new
`proposed/QwenLayerStageRankCutAdmissionCheck.swift` beside them. In the
`adapter-check` branch of `Main.swift`, immediately after the existing cut check:

```swift
try checkQwenLayerStageCutAdmission()
try checkQwenLayerStageRankCutAdmission()
```

The old cut fixture now expects 8 accepted / 53 rejected because serialized rank
is no longer foreign. The new pure fixture expects 8 accepted / 50 rejected.
These are source-derived expectations; root must compile and execute them.

## Scope and binding

Only native `qwen-layer-stage-compare` and `qwen-layer-stage-rank-check` accept
`--stage-cut`. The original CLI mode is checked before dispatch. Lookahead and
prefill-rank now reject a cut before rewriting their mode into serialized rank;
prefill and solo retain their comparison-clone rejection. No long mode changes.

The rank adapter preserves `stageCut` while changing only orchestration fields
for the existing comparison preflight. Literal bounds remain 1...127 and source
layers remain at most 128. The planner requires two contiguous complete ranges,
each at least one full-attention interval, with phase-aligned starts. It permits
an unaligned final model end. Missing cut keeps the existing even, phase-aligned
equal split and identical plan fingerprints. Bounds are checked before Range
construction, including programmatically mutated Options.

The runner reuses `ComparisonAdmission.validatePlanBinding` after option checks
and before `Collective`, request construction, model loading, or payload IO.
It rejects an explicit cut inconsistent with already-admitted Inputs. The
existing trust contract for other preflight fields is unchanged.

No model-width, quantization, arithmetic, loader, cache, session, wire, ACK,
request fingerprint, report, or cleanup changes are proposed. Actual source
ranges and plan/stage/construction identities already appear in the existing
load/frame evidence. The epoch still determines the fresh request UUID.
Prompt<=128, chunk<=32, output<=4, teacher history, native precision, one request,
zero warmups, timeout<=180, hidden<=8192 and the 512 MiB named-state/boundary
admission remain intact. That bound is not a process-memory guarantee.

## Review and checks

`source_checks.py` passed six packaging/ordering checks and rejected six source
mutations. It pins 17 unchanged planner/budget/loader/session/wire dependencies
and verifies the exact patch, captured bases and one-line runner delta. These
checks cannot establish Swift compilation or native correctness.

Transport peer and root independently reviewed the nine proposed Swift files
without a blocker. Native unequal-rank execution and parent numerical/resource
qualification remain pending; completed unequal one-process tests do not prove
this new two-rank path.

## Separate public Python work

The existing public `runtime/stage_checks` path assumes halves at these seams:

| File / symbol | Current dependency | Required explicit-cut handling |
| --- | --- | --- |
| `cli.py:parser` | No cut argument | A ranks-only optional argument and original command guard |
| `inputs.py:prepare` (line 45) | Even, phase-aligned half validation | Shared admitted ranges; retain only an explicit cut in context |
| `configuration.py:build` | Native argv has no cut | Forward one explicit pair to both ranks; omitted argv unchanged |
| `ranks.py:validate` (lines 30–31) | Frame source range equals rank times half | Compare actual captured range to retained admitted ranges |
| `evidence.py:state_entries` (lines 31–34) | Per-rank global/local state interval from half | Explicit ranges while retaining nil default for other callers |
| `storage.py:validate_pair` (lines 11, 30–31) | Parameter ownership and local mapping from half | Use source interval and global-minus-start mapping |

The Python proposal belongs to the transport peer in a separate outtree draft.
This package exposes no public Python flag and changes none of those files.
Its matching tests must cover stale half-range evidence, explicit unequal local
mapping, omitted default identity, and rejection by prefill/long/solo commands.
