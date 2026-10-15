# Resident cohort intent agreement

> Last updated: 2026-09-14 · commit `e4df336bc`

Apply `runtime.patch` to add seven files and replace four existing files. The
new adapter call is `try checkQwenLongPrefillResidentCohortAgreement()` after the
resident admission check. All work in this draft is outside the repository.
The new Swift fixtures and native exchange have not been compiled or executed
by the author. Root owns compilation, integration and actual qualification.

The pure `QwenLongPrefillResidentCohortAgreement` calls the existing local cohort
admission before accessing its first request. Its immutable descriptor binds the
ordered epochs, UUIDs, full recorded-request fingerprints and raw prompt pins;
common source, Plan, arithmetic/resource identity and policy; and one shared
warmup boundary. The existing 16-request cap applies before encoding and the
descriptor has a 16 KiB encoding bound. Raw prompts and configurations are not
exported in this descriptor. The actual selected Plan defines identity, so an
omitted cut and explicit historical half cut can describe the same cohort.

`QwenLongPrefillReadinessMaterial` has only two named domain factories and a
private initializer. The shared native helper extracts the original completed
[64] Int32/256-byte send/receive code. The old wrapper keeps the exact legacy
domain, group/disagreement error strings, rank order and result fields. Its
material still constructs inside the same `MLX.withError` scope. Only the final
CPU readiness DTO construction moves outside that scope; no native work moves.

The resident wrapper exchanges its separate cohort material after `Collective`
construction and before the sole verified stage load. It does not prove actual
loaded storage, resources or native precision. Every existing per-request
loaded-stage admission/readiness, forward loop, clock, phase/owner behavior and
retirement remains unchanged. An exchange error follows existing cohort cleanup
and prevents a successful cohort result. Existing parent deadline and whole-peer
fencing remain essential for blocking IO; mismatch is not a retry condition.

Only the new internal cohort report gains `cohortAgreement` and
`cohortReadiness`. Existing one-shot and per-request schemas do not change.
There is no new CLI or public launcher in this draft and no resident model,
performance or physical-transfer qualification.

The prospective CPU check has six accepted invariants, eight pairs of different
valid peer agreements, 17 actual admission rejections and four SHA vectors:

- Valid invariants cover deterministic bytes, fresh ordered A/B/A identities,
  bounded maximum and single cohorts, historical half identity and omission of
  rank-local paths.
- Distinct valid agreements isolate later history, UUID/epoch, order, count,
  warmup boundary, selected Plan and scheduling. A raw JSON whitespace change
  retains the exact recorded-request fingerprint while changing its raw pin.
- Rejections use actual Options and local/cohort constructors for list bounds,
  malformed/reused/mismatched identities, first-input pins, Plan substitutions,
  both trace paths and existing source/precision/policy gates.
- Two old readiness vectors preserve the retained domain; two new vectors show
  the independent cohort domain. All four were derived with Python SHA256 from
  fixed literal material, independently of Swift execution.

`check_source.py` passed source/patch checks and six rejected source mutations.
It verifies the old exchange body after only three named substitutions,
unchanged private owner/request/release code, the sole pre-load exchange and
exact four-file source bases. `git apply --check` passed read-only. These checks
do not stand in for Swift type checking, actual peer mismatch or shutdown tests.

`isolated-material-source-list.json` gives four exact files, in compile order,
for a Foundation/CryptoKit standalone run of just the four readiness vectors,
using the existing Candidate test SHA/ProbeError support. Its entry is
`standalone/ReadinessMaterialCheckMain.swift`. It is not part of `runtime.patch`.
The full cohort fixture deliberately uses actual `Options`, whose enum types
and admission dispatch reach the existing native target. Run those 6/8/17 cases
through the adapter branch after the canonical build; a small standalone version
would require substitutes or unrelated source extraction. Neither path ran here.

See `NATIVE_QUALIFICATION_PLAN.md` for the source-only model-free two-process
match, warmup-mismatch and missing-peer deadline route. It specifies no runnable
new command and claims no execution. That small qualification should precede
an actual resident model cohort.
