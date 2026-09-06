# Streamed SSD prefix cache model check

> Last updated: 2026-09-05 · commit `2a306f2f9`

The measured Qwen model restored encrypted complete checkpoints with normal MTP, exact generated-token parity and no resident prefix bank. One same-binary repeat improved from **6.578 to 1.836 seconds TTFT (72.09% lower)**, including SSD staging. The combined refactor also passed its direct-engine smoke. These are ordered single observations using an explicitly ephemeral key; production-key restart and live multi-provider routing remain unmeasured.

## Artifacts and measurement scope

The model was `EigenLabs/Qwen3.8-27B-4bit-mtp`, snapshot `06d517d395dfc5588090f7f534112bee331f7b4a`, verified aggregate `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`. Fresh hashes before and after model loading matched. All successful direct probes used the actual slot factory, a 16 GiB slot grant, backend `auto` resolving to contiguous, temperature zero and the active normal inline MTP assistant. The harness bound the runtime metallib before loading; it injected no prompt-contract or capability override.

| Artifact | Source / evidence |
|---|---|
| [Raw SSD build 3](evidence/ssd-prefix-2026-09-05/model-validation/artifacts/candidate-ssd-build3/artifact-manifest.json.gz) | Parent `d428ce5e6`, native library `72902c4a9`; engine SHA-256 `19ad280d027bf97ac2dd0f21add1581070ff9ef23efa6dc642e154f0ac9691e6` |
| Captured harness | Five source files match tools commit `4c744bc3f`; source/artifact manifests verified against 1,050 source/test blobs and 13 artifact entries |
| [Integrated release](evidence/ssd-prefix-2026-09-05/model-validation/artifacts/integrated-ssd-build1/artifact-manifest.json.gz) | Combined modules plus tools at `2eb19e269`, same native library; separate release artifact and model probe |
| Integrated full suite | [82 XCTest +2,506 Swift Testing tests /257 suites](evidence/ssd-prefix-2026-09-05/integrated-final/results.json), zero failures, source `97a439359`; tools merge preserves production bytes |

[The evidence manifest](evidence/ssd-prefix-2026-09-05/model-validation/manifest.json) retains reports, verdicts, commands, telemetry and artifact/source hashes. The raw probe includes SSD authentication/import and production staging reservations, but bypasses bridge request admission, HTTP framing and coordinator routing. TTFT starts before submission and excludes model loading/hashing. Terminal elapsed time includes durable publication; idle metrics follow reservation refund completion.

## Qwen latency and exactness

| Probe / case | Prompt tokens | Comparator TTFT (s) | SSD TTFT (s) | Saved tokens | Stage (ms) |
|---|---:|---:|---:|---:|---:|
| Same-binary donor | 5,523 | 6.093861, cache off | 6.091325 | 0 | 0.119 |
| Same-binary repeat | 5,523 | 6.577656, cache off | 1.835913 | 4,096 | 119.973 |
| Expanded original repeat | 5,523 | 6.563890, historical | 1.833588 | 4,096 | 120.459 |
| Expanded branch / repeat | 5,520 | 6.698433 / 6.768375, historical | 1.887368 / 1.913056 | 4,096 | 101.987 / 101.209 |
| Expanded turn two / repeat | 5,611 | 6.885920 / 6.893922, historical | 2.009064 / 1.988495 | 4,096 | 110.364 / 101.463 |
| Long original repeat | 12,091 | 15.115292, historical | 5.213929 | 8,192 | 203.480 |
| Long continuation | 12,099 | 15.366678, historical | 5.404102 | 8,192 | 193.261 |
| Integrated repeat | 5,523 | 6.125138, contemporary donor | 1.830254 | 4,096 | 119.367 |

All warm cases report actual matched checkpoint positions and zero replay. The 5,523-token repeat evaluates only the remaining 1,427 tokens. Names containing `p8192` are workload labels, not actual input lengths.

The long contemporary donor-to-repeat comparison is **14.326937 → 5.213929 seconds (63.61% lower)**; its historical repeat comparison is **15.115292 → 5.213929 seconds (65.51% lower)**. Neither is a same-binary cache-off long control. Each plan ran one ordered group; five expanded warm accesses are distinct cases, not independent repeats supporting a median claim. The short decode control had no cache hit: 55.533 versus 57.836 tokens/s establishes no decode improvement.

[Smoke verdict](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-smoke-verdict.json), [expanded verdict](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-expanded-verdict.json) and [long verdict](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-long-verdict.json) pass raw prompt IDs, generated IDs, text, token counts and finish reasons: respectively **644 IDs across eight measured pairs**, **903 across twelve**, and **452 across eight**, excluding warmup. The integrated probe matches all 644 measured IDs against both raw cache-on and cache-off reports ([integrated verdict](evidence/ssd-prefix-2026-09-05/model-validation/integrated-ssd-smoke-off-verdict.json)).

Raw reports retain complete output vectors and counters: [smoke](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-ephemeral-smoke/report.json.gz), [cache-off control](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-off-smoke/report.json.gz), [expanded](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-ephemeral-expanded/report.json.gz), [long](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-ephemeral-long/report.json.gz), and [integrated](evidence/ssd-prefix-2026-09-05/model-validation/integrated-ssd-build1-ephemeral-smoke/report.json.gz).

Each direct-engine plan includes fresh tenant A, its repeat and fresh tenant B with identical input: miss, hit, miss. A cancelled donor creates no reusable entry; its fresh-scope retry misses and then publishes after normal completion. These checks establish local scope/cancellation behavior, not network authorization. The different cancellation output counts reflect emitted delta boundaries and match their respective oracles.

## Publication cost and memory

| Primary donor / reuse | 5,523-token plan | Long plan |
|---|---:|---:|
| Files / bytes committed by donor | 1 / 464,388,145 | 2 / 1,239,198,644 |
| Donor write time | 112.254 ms | 295.395 ms |
| Final token → stream end | 113.696 ms | 299.068 ms |
| Bytes read per warm request | 464,433,910 | 774,882,258 |
| Maximum provider staging reservation | 587,218,940 bytes | 1,060,143,100 bytes |
| Warm writes / donation-read bytes | 0 / 0 | 0 / 0 |

The short cache-off donor tail was only 0.050 ms: publication has a measurable completion cost even though it follows TTFT. Each hit performs a manifest probe and authenticated checkpoint read, with maximum 4 MiB segments. The long donor's total spans two files; the per-read payload cap remains 1 GiB. No cap rejection was exercised. Staging reservations include native destinations and scratch, separately from that payload cap.

Every measured direct-engine SSD row finished with `staged_bytes_in_use = 0`, `memory_cache_enabled = false` and `resident_bank_budget_bytes = 0`. MLX active bytes returned to the loaded-model baseline of **15,371,851,945**. That is not zero RSS: weights remain loaded, MLX allocator cache can remain large, and operating-system ciphertext caching is separate. These counters do not prove process unload or OS memory reclamation.

## HTTP and eligibility limits

The integrated provider's real HTTP endpoint used normal slot construction,
bridge/shared request admission and SSE framing. Its historical normal-MTP
repeat improved from **6.566206 to 1.853455 seconds TTFT**; the contemporary
donor was 6.136915 seconds. All three request bodies, text, reasoning, token
counts and finish reasons match the correct normal-MTP baseline
([corrected HTTP verdict](evidence/ssd-prefix-2026-09-05/model-validation/integrated-ssd-http-corrected-mtp-verdict.json)). HTTP does not expose raw generated IDs, so exact-ID
proof comes from the direct probes. Disconnect cancellation completed and a
subsequent recovery request ended normally with `stop`.

The retained HTTP runner initially exited **1** because its input plan carried
MTP-off expected decode text. Offline comparison of that same execution against
the banked normal-MTP baseline passed; no request rerun or source change was
used to remove the initial failure. Both the [original execution](evidence/ssd-prefix-2026-09-05/model-validation/integrated-ssd-build1-ephemeral-http/http/report.json.gz) and corrected
verdict are retained, with original log/metadata. Earlier build-1/build-2 identity/setup failures and the
build-3 `persistentKeyUnavailable` attempt are also retained in the evidence
manifest; they are not successful cache measurements.

The GPT-OSS attempt stopped before any model request or cache-root creation. Its real 16,738-byte `chat_template.jinja` has SHA-256 `a4c9919cbbd4acdd51ccffe22da049264b1b73e59055fa58811a99efbd7c8146` and contains `strftime_now`, rejected by the existing `PromptContractIdentity.compute(modelDirectory:)` gate ([eligibility proof](evidence/ssd-prefix-2026-09-05/model-validation/ssd-build3-ephemeral-gptoss/eligibility-proof.json.gz)). No gate was bypassed. The earlier direct paged-L1 harness supplied a synthetic contract and does not establish SSD eligibility or streaming performance for this artifact.

All successful model results deliberately used an **ephemeral-key control**. Production-key reuse across a fresh OS process is unproven; existing signing/entitlement configuration is source evidence, not execution proof. Neither the direct harness nor local HTTP establishes live coordinator routing, and the coordinator cache-routing switch remains a separate default-off control.

The operating-system file cache was uncontrolled: repeats may read recently written ciphertext from RAM. These are encrypted stage/import timings, not cold physical-SSD bandwidth. Cache-on preceded cache-off; entry GPU temperatures were 27.25 °C and 37.57 °C. Retained telemetry includes load/warmup; high-utilization cache-on samples ranged from 1,457 to 1,620 MHz. There is no randomized ordering, matched per-row thermal normalization, broad throughput result or deployment claim.
