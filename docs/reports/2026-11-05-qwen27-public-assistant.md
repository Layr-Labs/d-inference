# Qwen3.8-27B tensor-parallel assistant on public traffic: parity evidence

> Last updated: 2026-11-05

This record is the evidence document of the provider's public declaration of Qwen3.8-27B's resident speculative
assistant on tensor-parallel pairs (`ClusterPublicTensorAssistant` on the Qwen3.8-27B entry of
`ClusterPublicModels.declared`). The declaration's `evidenceSHA256` is the SHA-256 of this file. A release's cluster
runtime facts give the model's serial-schedule tensor-parallel parity qualification this digest and instant (the
assistant needs serial prefill, so one-chunk-lookahead pairs decode plain and keep the model's evidence). It records the owner's
decision and the checks it rests on. It contains no endpoint, credential, machine identifier or personal workspace
location. It is not a hosted-provider certification or a production deployment approval.

## Decision

The owner (jonathan308) decided on 2026-11-05: "spec decode should be on and working for all and be much faster
through 2x", then "Finish the mtp fix and bench's then let's release .9". Two-Mac pairs that serve Qwen3.8-27B
through Darkbloom therefore decode with the assistant, as a local cluster and one Mac (MTP) already do.

## Declared assistant

| Runtime model | Catalog model | Artifact | Depth | Inventory (`--tp-mtp-inventory-sha256`) | Verification |
|---|---|---|---|---|---|
| `registered_qwen38_27b` | `EigenLabs/Qwen3.8-27B-4bit-mtp` | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` | 3 | `6bf428caf645e41cfda642108fc9a21d199ca999e80907be7476e87026afb014` | `admitted_target_cohort_v1` |

This is the policy local clusters already plan by themselves (`ClusterPlacementTensorAssistantSelection.automaticDepth`,
admitted cohorts). The inventory is the one the native metadata helper returns for the registered artifact
(`darkbloom-cluster-plan tensor-batch-scope --mtp-depth 3`, `QwenTensorParallelMTPInventory.footprint`). The placement is
the declared `tensor_parallel` family (`tensor_parallel_v1`, no cut). Through Darkbloom the shares are equal.

## What was run

The pair was an Apple M3 Ultra (256 GB, macOS 27.2) leading an Apple M5 Max (128 GB), over Thunderbolt, on DevNet
build `0.10.7-dev.branch.95`, the same build on both Macs. Requests went to the leader's local API, so every request
reached this pair and no other. The Mac Studio's display was in use (WindowServer took 40–55 % of its GPU).
The fixed requests:
- the 12 greedy prompts (6 prompts, thinking off and on) at 200 and 1,024 tokens;
- 4 sampled rows with fixed seeds (temperature 1, top-p 0.95; and temperature 0.7, top-p 0.9, top-k 40);
- a greedy row with logprobs (top 5);
- a tool call;
- one image.

A request that asks for logprobs decodes one token a step on an assisted pair. The assistant drafts only for
requests whose sampler admits speculative verification (`ClusterWorkerSampling.admitsSpeculativeVerification`: no
logprobs, no penalties, no logit bias), and media rows keep the target path
(`QwenTensorParallelNativeBatchExecutor`). So on one loaded pair, the same request with and without logprobs compares
the assistant's rounds with that pair's plain one-token path, with the same shares, weights, prefix state and build.

| Check | Result |
|---|---|
| Greedy, the 12 prompts at 200 tokens: speculative rounds against the same pair's plain steps (the same request with logprobs) | **12 of 12 identical** |
| Greedy, the 12 prompts at 1,024 tokens (answers of 47 to 608 tokens, each to its natural end), the same comparison | **12 of 12 identical** |
| Greedy repeatability: the assisted pair twice; the plain pair twice | 12 of 12 each |
| Sampled rows (fixed seeds), speculative against the same pair's plain steps | **4 of 4 identical** |
| Tool call, speculative against plain steps | identical, apart from the random tool-call ID |
| Image row | identical: media rows run the target path |
| Logprobs row | runs the plain path by design; repeatable |
| c1 = c4 (`cn_equal`, 256 tokens, every third row sampled): assisted pair | 4 of 4 equal to each row's solo answer |

A pair planned without the assistant gives other answers than the assisted pair for 8 of the 12 greedy prompts. The
logprobs row shows why. On both pairs it decodes one token a step, with no speculation, and still differs from the
first token on: −0.070116 against −0.070133 for the first token, at most 0.061 apart over 160 tokens. The first token
comes from the prompt's last row, before any draft. The local plan with the assistant split the layers 2:3
(`0-64@2|0-64@3`). The plan without it, made for Darkbloom, split them equally. Each split sums the row-parallel
partials over different shards. The rounding difference that follows flips near-ties later in an answer. The
assistant does not cause it. Through Darkbloom both setups use equal shares.

## Speed on this pair (decode tok/s, one request; four at once in total)

Over the leader's local API, the same build, the same hour (256-token answers):

| Setup | One request | Four at once (total) | First token | Prefill, 2K / 8K prompt |
|---|---:|---:|---:|---|
| Plain tensor parallel (equal shares) | 17.4 | 41.2 | 0.38 s | 516 / 558 tok/s |
| With the assistant (2:3 shares) | 39.7 | 47.6 | 0.38 s | 506 / 501 tok/s |

Decode at the 2K and 8K prompts: 16.6 and 16.4 tok/s plain, against 42.3 and 46.7 with the assistant.

The two rows are not like for like: the plain plan split the layers equally and the assisted one 2:3. The ratio
(2.3×) mixes the assistant's speed-up with the split's. The first DevNet build with this declaration measures both
through Darkbloom on equal shares.

On build `0.10.7-dev.branch.93`, with the 2:3 split: 25.3 with the assistant (four at once: 34.1).
The Apple M5 Max alone (single-Mac product path, MTP on) decoded 69.3–73.6 on build `0.10.7-dev.branch.92`.

## What this does not establish

- No request went through Darkbloom with the assistant: this build refuses it there. The first DevNet build that
  carries this declaration must repeat the same-request comparison through Darkbloom on equal shares.
- No run on two Apple M5 Ultras.
- Widths beyond four at once, prompts beyond 8,192 tokens, and the one-chunk-lookahead prefill schedule (the assistant
  requires serial prefill).
- How fast the pair is against one Mac. On this pair the M5 Max alone is still faster, for both plain and assisted
  tensor parallel.

## Where it is used

`provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift` declares the assistant
on the Qwen3.8-27B entry, with this file's SHA-256 (`ClusterPublicTensorAssistantTests` checks the digest). From that
declaration:
- a setup saved for coordinator pairing may carry exactly this policy (`ClusterConfiguration.validate`);
- the guided setup plans it under `mtp_mode = "auto"` (`ClusterPlacementTensorAssistantSelection.readAutomatic`);
- a release's cluster runtime facts, the coordinator's approval and every committed start carry it in the model's
  resource policy (`DistributedInstalledNativeStart.resourcePolicySHA256`);
- the model's serial-schedule tensor-parallel parity qualification carries this file's digest
  (`ClusterRuntimeApprovalFacts.parityQualifications`).
