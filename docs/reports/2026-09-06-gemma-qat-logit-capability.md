# Gemma QAT diagnostic capability refusal

> Last updated: 2026-09-06 · commit `1be058a6b`

The exact Gemma QAT4 artifact reproduces its 61-token contiguous control with
normal MTP. Installing the selected-logit diagnostic then fails with
`topTwoUnavailable` before the main requests run. The diagnostic depends on a
Qwen-specific MTP policy capability; this attempt provides no selected logits.

## Actual model result

The four-cell plan uses the same optimized probe for contiguous and paged
controls followed by their traced runs. Execution stops after the second cell:

| Cell | Result | Evidence |
|---|---|---|
| Contiguous, trace off | Pass | 5,418 prompt tokens; 61 output tokens; all seven completed trajectories exactly match the retained control |
| Contiguous, trace on | Diagnostic installation fails | Eight warmup tokens complete; both main rows are `not_run`; no selected capture |
| Paged, trace off | Unrun | Stopped after the capability refusal |
| Paged, trace on | Unrun | Stopped after the capability refusal |

All cells request cache off, normal configured MTP, B1, a 128-token output cap,
SSD storage, ephemeral keys and the production single-slot KV grant. The
September 6 prompt bytes and assistant configuration are pinned. The control's
output at index 7 is token 42392. The earlier contiguous/paged mismatch at that
position remains unresolved.

The failed diagnostic retires all active and waiting requests and native KV
reservations. The final owned-process inventory is empty. Normal model execution
is supported; this failure concerns diagnostic installation.

## Source diagnosis

`EngineLoopV2.configureLogitDiagnostic` requires
`cbv2MTPPolicyTopTwoAvailable`. The adapter forwards that capability from its
underlying model. Qwen implements it; Gemma4 does not. The capture path then
force-casts the corresponding provider protocol, so deleting only the guard
would be incorrect.

The existing Qwen top-two reducer is generic MLX computation, but lives in the
Qwen model module. Adding the policy protocol to Gemma could also change normal
marginal-MTP eligibility. A separate fix should move the reducer into common
code and decouple diagnostic reduction from policy eligibility, preserving the
Qwen wrapper and normal Gemma policy. That fix and its model rerun are pending.

## Provenance

The actual probe is built from parent `384c321aa7565864182c02210fc4d212efc6501b`
and native `e972340a7ba6e22fda5d8be1a7af918f9bf67b03`.
Probe SHA-256: `c15304623b6abc806fc47d312552eb888b10898ff6ef9f851e980fa1143578ba`.
Model aggregate SHA-256:
`2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`.
The selected assistant is the exact configured QAT assistant retained in the
runtime binding, with its config and weight hashes.

The first staging attempt fails before extraction because a template replacement
also modifies a literal containing `ROOT`. Its original source and error are
retained. The corrected controller uses a delimited placeholder and compiles
rendered programs before transport; four CPU regressions pass. Guarded staging
then resumes only the owned, unchanged archive. Eleven strict evidence tests
pass before the actual model runs. The model failure is retained without a retry.

The [manifest](evidence/gemma-qat-logit-capability-2026-09-06/manifest.json) and
[archive](evidence/gemma-qat-logit-capability-2026-09-06/payloads.tar.gz) preserve
134 independently rehashed payloads: plans, runtime bindings, source diagnosis,
raw reports and logs, strict results, staging failure and correction, and
postflight evidence. Binaries, model weights and keys are excluded.

Manifest SHA-256: `70087dd4c2bf0d51de6cf1668fa19861556d0acaffa9f090b92c3c9ef827e8b5`.
Archive SHA-256: `b4aef1a133bd3c5b76c2bf125a6ab2bb38c4d1b88bedf60b68fbe0482534a252`
(354,597 bytes).

This result does not establish numerical parity, a performance gain, persistent
restart behavior or release readiness. The previous backend/cache pilot remains
in [its frozen report](2026-09-06-q38-qat-backend-pilots.md).
