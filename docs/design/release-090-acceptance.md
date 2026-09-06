# 0.9.0 acceptance criteria

> Last updated: 2026-09-06 · commit `2eebb5412`

Status: **In progress** — 2026-09-06 — acceptance criteria clarified; execution and final release validation remain incomplete.

This supplements the [five-artifact activation decision](release-090-paged-qwen-cache.md). The release uses paged attention for all five listed artifacts, SSD caching by default for the three Qwens, and ordinary decoding for default-auto GPT-OSS and Gemma QAT. Gemma 8-bit and package-distribution changes remain outside this work.

## What constitutes correctness

Different coherent wording across attention backends is acceptable. Exact generated-token equality is a diagnostic, not a universal release condition. Keep original strict comparison results and investigate divergence using numerical controls, actual execution geometry and task quality. Do not convert an old failed comparison into a passing result by changing its tolerance or hiding its output.

Coherence alone does not establish correctness. A fluent answer can contain wrong arithmetic, omit a requested result or use another request's cache state. Acceptance therefore requires independent evidence:

| Check | Required evidence |
| --- | --- |
| Numerical behavior | Passing operator regression tests, finite model scores and investigation of material numerical differences; existing analytic tolerances remain unchanged |
| Model quality | Relevant, substantively correct answers or continuations to fixed representative tasks; record failures and inconclusive token-cap cutoffs individually |
| Serving configuration | Actual paged execution without unintended fallback; normal shipping MTP behavior; Qwen default SSD capability ready; GPT/QAT default SSD off |
| Concurrency and lifecycle | Actual B1/B2/B4 execution, long-context and sustained workloads, cancellation/recovery, complete owned-process retirement and shared-memory admission behavior |
| Qwen cache integrity | Real authenticated restores, complete same-backend cache-off/cache-on comparisons, tenant isolation, cancellation and recovery, durable restart with the production key path |
| Connected behavior | Valid HTTP streams and usage; live distinct-provider cache selection and cold fallback; stale, revoked and disconnected receipt handling |
| Final integration | Exact published dependency sources, versioned 0.9.0 build and smoke, relevant CI checks and review findings accounted for |

The unchanged strict same-backend SSD comparator is the initial cache regression check. Any mismatch needs a separate diagnosis; it is neither automatically harmless because the text is fluent nor automatically proof of cache corruption. Operator and model-quality evidence must remain distinct from cache identity, authentication and isolation evidence.

## Functional routing and physical measurements

A live multi-provider routing check may use distinct isolated provider processes on one sufficiently provisioned Mac. Each provider must have a distinct identity, owned process tree, cache root and key scope. Normal memory admission remains enforced. Evidence must demonstrate actual selection and fallback through the coordinator, rather than treating a single-provider hit as routing validation.

Such a run establishes functional behavior only. It does not establish independent physical-host capacity, network behavior or cross-machine performance. Older physical two-host attempts retain their original blocked or failed status. A second physical Mac is needed for those measurements; it is not an additional hardware-certification prerequisite for the functional check required by this release decision.

Coordinator routing activation remains a separate operational action, initially restricted to the three verified Qwen artifact tuples. Shipping provider defaults does not itself enable production routing. Persistent restart needs the accepted executable to access its intended Keychain group; ephemeral-key tests cannot substitute for that evidence. Changing signing or distribution workflows remains the user's separate work.

## Evidence and release state

Use bounded, explicitly identified test runs and preserve their failures. A process completing successfully, a small quality sample or a single restored prefix cannot establish release-wide acceptance. Conversely, a prepared larger experiment matrix does not make every historical diagnostic or physical performance experiment a new release requirement.

The current combined candidate and its numerical/cache results are recorded in the [candidate build report](../reports/2026-09-06-release090-candidate-build.md) and [Qwen 3.6 controls report](../reports/2026-09-06-qwen36-candidate-controls.md). Those binaries still report 0.8.16. Version metadata in the release branch is 0.9.0; the final build and smoke must establish that artifact separately.

Related: [validation procedures](../developer/test.md), [routing rollout](../operations/cache-routing-rollout.md), [prefix-cache architecture](../architecture/prefix-cache.md).
