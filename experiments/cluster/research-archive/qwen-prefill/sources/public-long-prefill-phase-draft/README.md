# Public long-prefill phase forwarding proposal

Source-only proposal; no public repository files were edited. Root integrates
the six files under `files/` after checking their intended paths and the four
saved originals. Native builds, SSH, model payload reads, actual processes,
sidecar retrieval and candidate replay were not performed here.

The public switch is `--prefill-phase-trace`, available only on
`long-prefill-ranks` and `long-prefill-solo`. It takes no path or value. The
existing per-owner directory substitution receives exactly
`--prefill-phase-trace-file @rank/phase-trace.json`.

Opt-in adds only `context.prefill_phase_trace: true` and the launcher receipt's
`phase_trace_request`: requested=true, expected owned relative paths,
included_in_rank_files=false, sidecars_verified=false,
phase_semantics_audited=false. These context/receipt fields are absent by
default. Native ready/report schemas, stdout/stderr rules, archived rank-file
sets, request bounds, environment, resource screens and whole-cohort cleanup
remain unchanged. Sidecar existence and content are intentionally not checked.

Add the new `runtime/stage_checks/long_phase.py` and
`test_stage_checks_long_phase.py`. Apply the minimal edits to `long_cli.py`,
`long_inputs.py`, `long_configuration.py` and `LONG_PREFILL.md`. The manifest
maps each complete draft file to its repository path and pins the exact
originals. `minimal-edit.patch` expresses the same six-file change. Keep the
frozen private launchers/readers and historical native reports unchanged.

The isolated source snapshot passed 81 stage-check CPU/fake tests: 72 existing
tests and nine new forwarding/ownership/default/failure tests. All process and
socket entry points are blocked; owned temporary file operations and fake
services exercise the entry. All 59 Python files parse as Python3.9. The first
test workspace omitted the unchanged thin public entry, causing two old entry
tests to fail; the omission/fix is retained separately. No product source was
changed for that test-harness fix.

This is prospective public option coverage, not execution through the public
launcher or a replay of new native phase results. The already completed native
proofs retain their private launcher/source identities. Root should run the
integrated runtime tests after copying the proposal; full worker/process tests
are not part of this agent's source-only stage-check run.
