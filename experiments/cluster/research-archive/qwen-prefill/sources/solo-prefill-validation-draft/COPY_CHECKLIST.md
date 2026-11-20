# Root copy checklist — solo native validation

Draft only; no repository files were changed by this handoff. The dated record
is ready to copy to `experiments/cluster/inference/QWEN_LAYER_STAGE_SOLO_PREFILL_VALIDATION.md`.
Its relative links resolve from that intended directory. Preserve the earlier
stage pilot and 14-cohort study records unchanged.

1. Copy the validation record. It binds the completed native run, 54-test
   unchanged numerical oracle and separate provenance/postflight receipts.
2. In `experiments/cluster/inference/QWEN_LAYER_STAGE_SOLO_PREFILL.md`, replace
   the bold build-only status with:

   > **Current status: the guarded registered-9B solo request and independent
   > final-state/logit-digest audit passed. See the [dated native validation](QWEN_LAYER_STAGE_SOLO_PREFILL_VALIDATION.md)
   > for the single timing observation and its limits. A public solo launcher is
   > not available.**

   Keep the build/parser counts as historical build evidence, but replace
   “These are build/parser checks, not model parity or timing results” with
   “These build/parser checks are separate from the dated native validation.”
   In “Guarded inputs and reference trust”, replace the first sentence with
   “A private guarded launcher and independently audited reference producer
   were used for the dated validation; there is no public solo-launch command.”
   Keep the admission, reference-trust and timer explanation intact.
3. In the inference README, replace the current final three lines of the solo
   paragraph with:

   > defines a pinned final-reference contract and the corresponding single-process
   > timer. Its [guarded registered-9B validation](QWEN_LAYER_STAGE_SOLO_PREFILL_VALIDATION.md)
   > passed with final-state/logit-digest agreement. The single new-binary timing
   > point does not qualify acceleration; a public solo launcher is not available.

4. In `docs/developer/test.md`, replace the pending guarded-model sentence with:

   > describes the additive full-model control, strict reference admission and timer
   > boundaries. The [guarded registered-9B solo validation](../../experiments/cluster/inference/QWEN_LAYER_STAGE_SOLO_PREFILL_VALIDATION.md)
   > passed independently checked final-state/logit digests and selection; its
   > single timing point remains unqualified for acceleration or resident throughput.

5. Keep the date/verified commit stamp `2026-09-14` / `e4df336bc`; run root's
   normal docs-link/private-source scan after copying. No native rerun is needed.

The draft quotes the arithmetic audit's candidate SHA-only limit: no raw
candidate row or state is exported, no new candidate tie count is computed,
and the post-stop field excludes later model release/cache clearing/report.
The earlier 14-cohort study ran binary `9341ca3b…`; this solo point ran `9195a464…`.
No cross-study ratio, physical transport, 8K, warmed serving or M3 Ultra claim is added.
