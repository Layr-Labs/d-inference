# Fixed instruction-prefix KV retention candidate

> Last updated: 2026-10-09

This is a separate benchmark candidate after the
[frozen half-retention campaign](2026-10-09-selective-kv-working-set.md).
It protects a fixed 128-token instruction prefix before choosing older chunks.
Serving remains disabled. The policy and twelve new cases are fixed before
candidate GPU evaluation; no quality result is claimed at registration.

## Fixed policy and scope

`DARKBLOOM_CBV2_SELECTIVE_KV=instruction-half` requires a GPT-OSS singleton
benchmark, an explicit contiguous backend, MTP off and prefix reuse off. It
keeps four anchors, at least 512 recent entries and half of older history in
16-token chunks; compaction starts after 4,096 prompt positions and occurs no
more often than every 256 positions. The new typed prefix field is bounded to
256 tokens, but this candidate is fixed at 128. The original `half` mode leaves
that field zero and preserves its previous behavior.

Native dtype, absolute positions, configured windows, speculative guards and
conservative native reservation remain unchanged. More prefix entries survive
selection; no allocation, activation, admission or OS-memory safeguard is
reduced. Full FP32 key-history casts, normalization intermediates and
source/destination overlap remain present and unqualified for serving. This
cohort changes no scorer arithmetic or model weights.

## Native CPU header audit

The audit uses the actual production normalization and local tokenizer. From
the normalized message structure it renders the system/developer/tool prefix
followed by an empty first user. The last structural user marker locates the
boundary; the resulting prefix must exactly match the full prompt's tokens.
An earlier literal user marker inside a tool description cannot shorten it.
Missing or mismatched boundaries are unverified, rather than silently inferred.

`radix-engine --prompt-audit-only` performs this operation without constructing
a model, loading weights, binding Metal or evaluating an MLX array. The twelve
new cases have verified boundaries of 64 tokens for arithmetic/code and
118–124 for tools. All fit the fixed 128-token prefix. The unchanged recovery
request has 4,602 tokens and a 64-token boundary; its full prompt IDs exactly
match the original frozen native report. The generation harness rejects
unverified headers or headers exceeding 128 in the candidate arm.

Raw teacher-forced probes protect the numerical first-token span but do not
establish structured-header coverage; that evidence comes from this audit and
its generation cohort.

## Preregistered cohort

[The preregistration](../assets/2026-10-09-instruction-prefix-preregister.json)
retains the policy, controls, input/audit hashes and decision rule. The
[new inputs](../assets/2026-10-09-instruction-prefix-new-input.json.gz),
[oracles](../assets/2026-10-09-instruction-prefix-oracles.json) and
[native audit](../assets/2026-10-09-instruction-prefix-new-audit.json.gz)
preserve twelve previously unmeasured cases: four arithmetic, four code and
four tool prompts at approximately 4.5K/8.5K contexts. Every answer cap stays
256. Native baseline failures remain separate from candidate regressions.
This handcrafted set does not support a statistically broad quality claim.

The unchanged [recovery input](../assets/2026-10-09-instruction-prefix-recovery-input.json.gz)
and [native audit](../assets/2026-10-09-instruction-prefix-recovery-audit.json.gz)
preserve six complete observations per arm: main request, three fresh scopes,
donor and recovery. The first main request uses the existing bounded index-47
logit diagnostic; five subsequent replays are uninstrumented. Compare their
emitted IDs and exclude instrumented timing from performance claims.

The [frozen first divergence](../assets/2026-10-09-instruction-prefix-frozen-divergence.json)
is output index 47, absolute position 4,649: native chooses token 7,890
(` seems`), while the original half policy chooses 6,960 (` likely`). Both
share the preceding generated prefix. The longer subsequent reasoning is a
diagnosis, not proof that lost instructions caused the failure. Prefix
protection also changes the older chunk partition and budget; even a behavior
change cannot isolate semantic instruction loss as the sole cause.

## Validation status

The native CPU audits and radix build pass. The mandatory dedicated refactor
found and fixed an environment-injection mismatch: the same effective
environment now selects the engine policy and validates header coverage.
Rebuilt CPU audits preserve every preregistered prompt token. Two direct SDK
tests and thirteen provider tests pass, covering repeated pruning, rollback,
header validation, factory restrictions and unchanged native reservations.
The original four-anchor policy remains the regression control.

Final component checks and the fixed model cohort are separate gates. GPU
phases remain serialized with other cache work. This record retains every
outcome, including failures, rather than retuning the same labeled holdout.
