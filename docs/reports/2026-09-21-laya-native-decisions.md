# Laya native decision integration

> Last updated: 2026-09-21 · commit `ce809b792`

The English Laya checkpoint runs through native Swift/MLX, and its typed
answers match the independent Python MLX implementation on seven qualification
cases. Local provider HTTP and encrypted request/response tests pass. This
record describes development evidence; model publication, signed-release
qualification, production deployment and traffic activation are separate.

## Sources and artifact

| Item | Exact input |
|---|---|
| API reference | [TypeSafe System One](https://docs.typesafe.ai/api), `POST /v1/systemone` |
| Original model | [Convai Innovations Laya](https://huggingface.co/convaiinnovations/laya), revision `c5d78730f3493e4fe16d61507ef4b78eef7318cf` |
| FP16 artifact | [aac6fef/laya-mlx](https://huggingface.co/aac6fef/laya-mlx), revision `20aed815fc6acde75733882e7ec0e3f28aeb9717` |
| Independent reference | [mizorewww/laya-mlx](https://github.com/mizorewww/laya-mlx), revision `fc1df62828a3fedf4d8229fdac1cbd85f1cdf337` |
| Weight file | 842,609,225 bytes; 206 FP16 tensors; 421,293,830 stored elements including buffers |
| Weight SHA-256 | `b9c07bf14be2fa5c78a9193a3e6d840ac80e89e62fc40f425834c3d8a6eaa3de` |
| Download verification | `hf cache verify` checked all 12 remote files at the pinned revision |
| Hardware | Apple M4 Max, 128 GiB unified memory |
| Reference runtime | Python 3.14.3, MLX 0.32.2 |
| Native runtime | Swift 6.3.3; repository-pinned MLX Swift/core; source-matched metallib SHA-256 `2129f6132794d84243c02631bc7478417dba0e0dbd10467beab56c11bf20bdd2` |
| SDK source | `327af8b9412be6967873077682d67d9b6fe6ba9a`, [SDK PR #156](https://github.com/Layr-Labs/mlx-swift-lm/pull/156) |
| Native publish artifact | [Eight-file manifest](../assets/laya/manifest.json), including license/notices; aggregate `1c9dacab4be23506e8b182ba5aaeb5ac608e73627d369e96396db0774b2ade20` |

Laya is a bidirectional ModernBERT encoder with a decision transformer and
calibrated scoring/action heads. It does not generate text. This implementation
does not download or run TypeSafe's proprietary Jev weights.

## Numerical qualification

The [machine-readable comparison](../assets/laya/native-parity.json) covers
27 questions across seven requests:

| Case | Questions | Encoded input tokens |
|---|---:|---:|
| Mixed choice/score/noul | 3 | 127 |
| Single-option choice and padding | 2 | 78 |
| Structured Unicode instructions/state | 1 | 76 |
| 512-token context boundary | 1 | 512 |
| Eleven-option calibration bucket | 1 | 40 |
| Numeric JSON lexical normalization and large integers | 1 | 111 |
| Request spanning the 16-question batch boundary | 18 | 672 |

All token IDs, marker positions, question types, selected labels, legends and
token usage matched. All rounded answer values matched exactly. Maximum
absolute decision-logit difference after JSON diagnostic decoding was
`5.000000014021566e-08`; action logits matched. Output usage was zero in every
case. The JSON report records the numerical acceptance tolerances explicitly.

An independent code review identified a separate FP16 matmul-plus-bias in the
initial port. Matching reference `nn.Linear` with fused `addMM` removed the
observed logit differences. The final comparison includes that correction.

This is implementation parity on a finite fixture set, not a task-accuracy
benchmark, calibration study, or evidence that Laya matches Jev's quality.

## Local runtime measurement

The [recorded benchmark](../assets/laya/native-benchmark.json) used
[one three-question request](../assets/laya/benchmark-request.json), five warmup
calls and 30 measured calls on the M4 Max. The request encoded 132 input tokens
in total and produced zero output tokens.

| Observation | Value |
|---|---:|
| Median warm runtime | 32.10 ms |
| Minimum–maximum warm runtime | 25.90–69.73 ms |
| Checkpoint/tokenizer load time | 0.484 s |
| Active MLX allocation after measurement | 842,602,010 bytes |
| Peak MLX allocation in the process | 1,041,208,465 bytes |

Timing includes JSON parsing, tokenization, native inference and result
serialization, and excludes HTTP/network latency. Median is the arithmetic
mean of the two middle observations for the even-sized cohort. Allocation
figures are MLX allocator statistics, not total RSS. The development host was
not dedicated to benchmarking; these results are not fleet latency or an SLA.

## HTTP and provider evidence

The [real local HTTP checks](../assets/laya/http-smoke.json) exercised a native
`mlx-server` on loopback: health/model discovery, mixed decisions (HTTP 200,
132 input tokens and zero output tokens), malformed JSON (400), wrong model
(404), and generation controls/scalar state (422). The
[example response](../assets/laya/http-response.json) contains all three types.

The provider's opt-in real checkpoint test separately exercised its shared
load gate and fresh hash bracket, native local HTTP, startup self-test,
encrypted request decryption, encrypted decision response, authoritative zero
completion tokens, busy-eviction refusal, unload, and zero pending KV leases.
It used ephemeral test identities, not production Apple attestation or a signed
release artifact.

## Regression validation

- SDK: 15 XCTest cases and 15 Swift Testing cases passed, including the real
  tokenizer's oversized-header rejection and existing server surfaces. DocC
  generation passed with warnings as errors; fork-diff coverage and merge-base
  checks passed.
- Coordinator: the complete unit suite and native host build passed. The
  subsequent native cache-exclusion repair passed focused race checks and a
  rebuilt host binary. Linux/amd64 cross-build passed.
- Provider: the canonical full suite passed 143 XCTest cases (8 existing
  fixture skips), 3,070 Swift Testing cases, and its isolated suites. Final
  native refinements passed 11 XCTest and 54 Swift Testing regressions; a
  subsequent capacity-reporting adjustment passed all six native tests,
  including the real checkpoint. Native fixture tests were enabled explicitly.
- Console: 796 tests across 102 files, the production build/TypeScript, and
  lint passed. Lint retains existing warnings. One earlier default-worker run
  timed out in an unchanged billing smoke test under concurrent build load;
  the complete two-worker rerun passed without changing the test.

## Serving limits and rollout

- The qualified English format is FP16, 512 tokens per question, a 192-token
  nominal header budget and two decision-head layers. State is truncated from
  the right after reserving question/option tokens.
- Up to 64 questions run in batches of 16. One request owns native execution
  per provider. Cancellation retains ownership until submitted GPU work ends.
- Decision and autoregressive slots initially have exclusive residency. The
  existing memory cap, unmeasured activation reserve and load/headroom gates
  remain in force.
- Public discovery identifies a decision model. Generation endpoints reject
  it, and the OpenRouter generation feed excludes it.
- The draft rate is $0.01 per million encoded input tokens and $0 output. The
  input price is provisional. State tokens count separately for every question.
  Existing direct-account billing retains its $0.0001 request minimum.
- The 16 GiB draft minimum is a conservative pilot policy, not physical
  qualification of a 16 GiB device. Only the 128 GiB M4 Max was measured here.

Use the [onboarding runbook](../operations/laya-onboarding.md) for immutable
publication, approved pricing, signed-provider qualification, coordinator
deployment, canary verification and public alias activation.
