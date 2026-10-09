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

## Fixed candidate outcome

The fixed candidate **does not rescue the original regression**. Native
answers correctly in all six recovery observations at 164 tokens. The
128-token candidate reaches the 256-token cap in all six, without the final
answer. Each arm is internally token-exact across the instrumented main and
five uninstrumented observations. The original campaign is unchanged.

On the twelve new cases, native and candidate each pass ten. Both fail
`4k-arithmetic-b` and `8k-arithmetic-d` by reaching the same 256-token cap;
the candidate introduces no additional oracle failure on this small set.
Only four of twelve complete generated token arrays are equal. Equal answer
counts therefore do not mean equal model behavior or broad retention quality.

| New case | Native tokens | Candidate tokens | Answer oracle, both arms | Complete token arrays equal |
|---|---:|---:|---|---|
| `4k-arithmetic-a` | 77 | 189 | Pass | No |
| `4k-arithmetic-b` | 256 | 256 | Fail: cap | No |
| `4k-code-a` | 171 | 171 | Pass | Yes |
| `4k-code-b` | 185 | 187 | Pass | No |
| `4k-tool-a` | 192 | 192 | Pass | Yes |
| `4k-tool-b` | 119 | 119 | Pass | Yes |
| `8k-arithmetic-c` | 147 | 157 | Pass | No |
| `8k-arithmetic-d` | 256 | 256 | Fail: cap | No |
| `8k-code-c` | 191 | 191 | Pass | Yes |
| `8k-code-d` | 226 | 190 | Pass | No |
| `8k-tool-c` | 108 | 107 | Pass | No |
| `8k-tool-d` | 111 | 109 | Pass | No |

At the bounded diagnostic, the complete generated prefix before output 47
matches. Both captures use the same native control geometry and query cache
offset 4,648; the emitted output token occupies absolute position 4,649.
Native chooses ` seems` (7,890), while the candidate chooses ` likely`
(6,960). The raw logit margin, 7,890 minus 6,960, changes from +0.06152153 to
−0.01633263. Both records are confirmed and finite. These are two raw logits,
not full-vocabulary probabilities. Instrumented timing is excluded from
performance evidence. Protecting the audited header is insufficient to fix
this behavior; the experiment does not identify which other removed entries
cause the logit change.

Every new candidate case emits twelve pruning events, one per full-attention
owning layer. Last-prune native KV backing retains 56.45–59.28% of its source
storage, including the bounded append capacity. This counter excludes scorer
scratch and overlapping source/destination buffers. At the common output-8
observation, candidate active allocation is 92.25–93.06 MiB lower for the
approximately 4.6K prompts and about 189 MiB lower for the approximately 8.7K
prompts. These are sampled process allocator deltas, not per-request ownership
receipts or additional admission capacity. In the new-cohort runs, whole-run MLX peaks remain
essentially unchanged: 13.75019 GiB native and 13.75014 GiB candidate. No
speedup is claimed. All four cells complete their strict token comparisons,
observed cancellation, donor recovery and idle/shutdown ownership checks.

The [frozen artifact manifest](../assets/2026-10-09-instruction-prefix-artifact.json)
binds parent `f2fb32afae48f4a7fbce4779002103d6de50d005`, SDK
`f328058257f23b22607e73bbe5325c2e597c130d`, binary
`d054816fd0b5c842d1d4fe5a6af9e8477f60305a3af6a0f0ad93cdcee248245a`,
source-matched metallib and model hashes. The
[comparison](../assets/2026-10-09-instruction-prefix-comparison.json),
[exact commands](../assets/2026-10-09-instruction-prefix-commands.json) and
[artifact checksums](../assets/2026-10-09-instruction-prefix-results-manifest.json)
preserve the complete outcome. Raw observations remain available:

- Recovery: [native](../assets/2026-10-09-instruction-prefix-recovery-0.json.gz)
  and [candidate](../assets/2026-10-09-instruction-prefix-recovery-instruction-half.json.gz).
- New cohort: [native](../assets/2026-10-09-instruction-prefix-new-holdout-0.json.gz)
  and [candidate](../assets/2026-10-09-instruction-prefix-new-holdout-instruction-half.json.gz).
- Final frozen-binary CPU audits: [recovery](../assets/2026-10-09-instruction-prefix-recovery-final-prompt-audit.json.gz)
  and [new cohort](../assets/2026-10-09-instruction-prefix-new-holdout-final-prompt-audit.json.gz).

## Validation status

The native CPU audits and radix build pass. The mandatory dedicated refactor
found and fixed an environment-injection mismatch: the same effective
environment now selects the engine policy and validates header coverage.
Rebuilt CPU audits preserve every preregistered prompt token. Two direct SDK
tests and thirteen provider tests pass, covering repeated pruning, rollback,
header validation, factory restrictions and unchanged native reservations.
The original four-anchor policy remains the regression control.

The final CPU-only radix gate passes 33 tests, and canonical
`make provider-build` passes. Hosted provider unit, SDK and prompt-parity checks
pass at the frozen source head. The standalone SDK build/test gate is still
running. The published Before/After Mermaid diagrams in the
[provider draft](https://github.com/Layr-Labs/d-inference/pull/1417) and
[SDK draft](https://github.com/Layr-Labs/mlx-swift-lm/pull/297) were visually
verified on GitHub. Global documentation lint still fails only on the
inherited frozen-report reference to absent
`coordinator/registry/cache_match_groups.go`; that frozen record is unchanged.

The quality failure and unqualified scratch bounds keep both changes in draft
and serving disabled. No second policy was tuned against these outcomes.
