# Qwen production-default HTTP smoke, 2026-09-06

> Last updated: 2026-09-06 · commit `2eebb5412`

All three Qwen models passed the two-request production-default HTTP smoke on the reviewed104 correctness runtime. Each provider was configured with backend `auto`, MTP `auto`, and cache enablement unset. Each actually selected paged attention without a fallback, advertised an enabled and ready complete SSD cache for the exact model and prompt contract, and used MTP. Each cold request donated a checkpoint; its repeat reported an SSD hit restoring 4,096 tokens with no required recomputation.

| Model | Prompt + completion = total, each request | Repeat restored tokens | Cold / repeat total time | Verdict |
| --- | --- | --- | --- | --- |
| Qwen3.6 35B A3B VL MTP MXFP8 | 5,503 + 64 = 5,567 | 4,096 | 3.847 / 0.884 s | Passed |
| Qwen3.5 35B A3B | 5,503 + 64 = 5,567 | 4,096 | 1.876 / 0.876 s | Passed |
| EigenLabs Qwen3.8 27B 4bit MTP | 5,545 + 64 = 5,609 | 4,096 | 7.487 / 2.759 s | Passed |

Cold and repeat responses matched content, reasoning, tools, finish reason, prompt tokens, completion tokens and total tokens. Counts were positive and consistent; all requests returned HTTP200 with a completed stream. Request-level lookup and completion-usage receipts establish restoration; periodic cache-store counters can lag and are not the restoration evidence. These single-run times describe only these requests, not a throughput benchmark.

The 64-token cap is a material limit: all six responses consisted entirely of reasoning, with empty final content and `length` termination. This proves default selection and bounded cache replay behavior, not answer quality or task completion. It covers one provider at batch size1 with two text requests per model. It does not validate B2/B4, long-context sustained generation, tools, vision, cancellation, multi-provider routing choice, persistent keys, or reuse across process restart. Keys were explicitly ephemeral under isolated per-provider test roots; cache enablement remained the production default. The actual native artifact still reports0.8.16; the separately prepared0.9.0 version-only rebuild and its defaults smoke are not represented as passed here.

The earlier107 Qwen3.6 attempt is preserved as a failed fixture startup with zero HTTP requests. Its revision-directory symlink was skipped by Foundation discovery, so the provider reported `No models selected.` Successor125 used real HF revision directories with exact manifest-bound file links through each projection's own blobs root. The actual Foundation scanner and cleanup guards passed CPU tests; production scanner code and model bytes were unchanged. All three125 cells completed under a live external caller lease, and their owned process groups retired. The temporary Qwen3.6/Qwen3.5 projections were removed with their journals preserved. A fresh final observation found no owned or unexpected jobs before the M5 lane was released.

The accompanying [evidence projection](evidence/qwen-default-http-2026-09-06/evidence.json) binds exact model aggregates, prompt contracts, input/binding/runtime/Go/controller hashes, all six request results, request-level SSD and MTP observations, original full-report/archive hashes, root reviews and cleanup evidence. It contains no prompts, generated text, raw SSE, provider-config contents, credentials, model weights, binaries or cache payloads. The original sealed reports and the failed107 evidence remain retained privately.

The [projection capsule](evidence/qwen-default-http-2026-09-06/evidence.tar.gz) and [checksum](evidence/qwen-default-http-2026-09-06/archive.json) preserve the selected evidence and extraction script. See also [GPT-OSS and Gemma QAT default checks](2026-09-06-gpt-qat-default-http.md).
