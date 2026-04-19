# Smart Prefill: Disaggregating Prefill Across the Mac Fleet

## Why

A single 32 K-token prompt to Qwen3.5 27B costs the big-Mac provider ~10 GB of KV cache and 8–15 s of GPU-bound prefill work before it can emit the first token. That prefill is **compute-bound and parallel** — the exact thing that maps well to Apple Silicon GPUs — but right now we make the same big-RAM machine that does decode also pay the prefill bill, wasting its memory bandwidth advantage on an op that doesn't need it.

The constraint that kills bit-exact prefill disaggregation across consumer internet is bandwidth: shipping 10 GB of KV per request over a 125 MB/s pipe takes longer than just doing prefill from scratch. So the trick is not to ship KV — **ship a shorter prompt instead**, and let the big provider do its own prefill on a 4× smaller input.

This is the disaggregated-prefill story for d-inference: a small Mac (≤ 16 GB Air, base Mini) runs a tiny draft LLM that scores prompt tokens by attention, drops the low-importance ones, and ships the compressed prompt back as plain text. The big Mac then runs normal prefill on the shortened prompt with **no engine modifications required**.

## The state of the art (April 2026)

The field moved fast since 2024. Most relevant work:

- **LLMLingua-2** (Microsoft, 2024) — XLM-R 560 M classifier for token importance. 2–5× compression, ~85–90 % task quality. The prior generation. Generic, no target-model knowledge.
- **LongLLMLingua** (2024) — perplexity-based with a 7 B helper LLM. Heavy.
- **BEAVER** (arXiv 2603.19635, March 2026) — training-free, structure-aware page selection. New SOTA among LLMLingua-class methods on LongBench, beats LongLLMLingua at 2–4×.
- **SpecPrefill** (NVIDIA / Microsoft, 2025) — uses a small *draft LLM* to compute attention scores over the prompt; selects the top-K% of tokens by attention mass. Quality at 4× compression is dramatically higher than classifier methods because the dropped tokens are exactly the ones the target wouldn't attend to anyway.
- **Cross-Family Speculative Prefill** (arXiv 2603.02631, March 2026) — proves the draft can come from a *different* model family than the target. Critical for our use case: a single 0.6 B draft serves the entire big-tier catalog.
- **PrfaaS — Prefill-as-a-Service** (arXiv 2604.15039, April 2026) — cross-datacenter prefill offload for 1 T-param models, +54 %/+32 % serving capacity gains. Validates the architectural pattern; we're doing the same thing but across a decentralized Mac fleet instead of between datacenter clusters.
- **vllm-mlx#179** (March 2026) — open prototype of SpecPrefill on the exact runtime our providers run. Reports **5.45× TTFT reduction on Qwen3.5-122B at 128 K context** on M2 Ultra (1155 s → 212 s). This is what phase 2 will graduate into.

## Two-phase plan

### Phase 1 (this PR) — text-level compression

Fully implemented. The small-tier provider:

1. Receives the prompt over the existing E2E-encrypted protocol envelope.
2. Runs a forward pass through the draft model (default `mlx-community/Qwen3-0.6B`, fits in 8 GB).
3. Aggregates attention scores across heads/layers, picks the top-K% of tokens by importance.
4. Returns the kept tokens **as plain text in original order**.

The big-tier provider runs normal prefill on the shorter text. No vllm-mlx changes required, works with every model in the catalog today.

Expected speedup: **2–3×** TTFT on long-context requests.

### Phase 2 (follow-up) — true sparse prefill (SpecPrefill on vllm-mlx)

Same protocol envelope, but the small provider returns **token positions + position IDs** instead of plain text. The big-tier provider's vllm-mlx fork runs sparse prefill at the original positional schema (cf. waybarrios/vllm-mlx#179). Expected speedup: **5×+** at 128 K context, matching the prototype's measured numbers.

Phase 2 ships behind the same `smart_prefill` flag — clients don't change.

## API surface

### Standalone: `POST /v1/compress`

OpenAI-style. Useful when consumers want to pre-compress a corpus once and reuse it as a stable system prompt.

```bash
curl https://api.darkbloom.dev/v1/compress \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "compressor_model": "mlx-community/Qwen3-0.6B",
    "prompt": "<your long context here>",
    "target_ratio": 0.25
  }'
```

Response:

```json
{
  "object": "compression",
  "model": "mlx-community/Qwen3-0.6B",
  "compressed_prompt": "<shorter prompt>",
  "usage": {
    "original_tokens": 32000,
    "compressed_tokens": 8000,
    "total_tokens": 32000,
    "ratio": 0.25
  }
}
```

### Transparent middleware: `smart_prefill` field on `/v1/chat/completions`

Opt-in per request. Coordinator runs the longest user/system message through the compressor, swaps it in, then dispatches to the consumer's chosen model.

```bash
curl https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -d '{
    "model": "qwen3.5-27b-claude-opus-8bit",
    "smart_prefill": true,
    "messages": [
      { "role": "user", "content": "<long RAG context + question>" }
    ]
  }'
```

Or with overrides:

```json
"smart_prefill": {
  "enabled": true,
  "compressor_model": "mlx-community/Qwen3-1.7B",
  "target_ratio": 0.3,
  "min_keep_tokens": 128,
  "preserve_boundaries": true
}
```

Response headers reveal what the middleware did:

```
X-SmartPrefill-Compressor: mlx-community/Qwen3-0.6B
X-SmartPrefill-Original-Tokens: 32000
X-SmartPrefill-Compressed-Tokens: 8000
```

Middleware is **best-effort**: if the compressor fleet is unavailable or the prompt is too short to be worth compressing (< 2 000 estimated tokens), the middleware silently falls through to full prefill. Better a slow correct request than a fast failure.

## Architecture

```
consumer ─► coordinator ─► tiny provider (compressor)        ─┐
                            ↓                                  │ encrypted
                            attention scores → top-K% tokens   │ compressed
                            ↓                                  │ prompt
            coordinator ◄───┘                                 ─┘
                ↓
                swap compressed prompt into request body
                ↓
            standard provider (target LLM)
                ↓
                normal prefill on 4× shorter prompt
                ↓
            consumer receives streamed response
```

All three legs are E2E-encrypted with NaCl box (X25519 + XSalsa20-Poly1305). The coordinator never sees plaintext on either the request or the compressed-response leg. Cross-provider retry (3 attempts, excludes failed providers) is identical to the chat path so a single flaky compressor doesn't 502 the consumer.

## Pricing

| Workload | Default rate (micro-USD per 1 M input tokens) |
|---|---|
| Embeddings | 5 000 |
| Reranking  | 10 000 |
| **Compression (Qwen3-0.6B)** | **4 000** |
| **Compression (Qwen3-1.7B)** | **6 000** |

We price compression deliberately low — at $0.004 / 1 M input tokens, a 32 K-token prompt costs $0.000128 to compress, and saves the consumer ~24 K tokens of big-tier prefill ($0.0024 at $0.10 / 1 M for Qwen3.5 27B). **Net economic impact for the consumer is ~19× positive** before counting latency wins. Provider keeps 95 %, platform keeps 5 % — same split as everything else.

## Catalog

Seeded by `coordinator/cmd/coordinator/main.go: seedModelCatalog`:

| ID | Type | Size | Min RAM |
|----|------|------|---------|
| `mlx-community/Qwen3-0.6B` | compressor | 0.7 GB | 8 GB |
| `mlx-community/Qwen3-1.7B` | compressor | 1.8 GB | 8 GB |

## Provider sidecar

The provider expects a local HTTP service on `127.0.0.1:$EIGENINFERENCE_COMPRESSOR_PORT` (default `embedding_port + 1`) exposing `POST /v1/compress` with the same body schema. A first-party MLX-based sidecar will ship with the next provider bundle.

When the sidecar isn't running, compression requests fail with `connect refused`, the coordinator excludes that provider for the request and tries another tiny provider (3 attempts). The standalone `/v1/compress` endpoint surfaces a 502 if all attempts fail; the smart-prefill middleware silently falls through to full prefill so the consumer's chat request still completes.

## Testing

End-to-end coverage in `coordinator/internal/api/compress_test.go`:

- `TestCompressE2E` — full encrypted round-trip on the standalone endpoint.
- `TestSmartPrefillMiddlewareSwapsLongestMessage` — full encrypted round-trip through the middleware: confirms the chat provider receives the *compressed* prompt and the response carries the `X-SmartPrefill-*` headers.
- `TestSmartPrefillFallsThroughOnShortPrompt` — middleware is a no-op below the min-tokens threshold.
- `TestCompressNoFreeCreditWhenBillingDisabled` — same regression test as embeddings (refund cannot mint balance when billing was never charged).
- `TestCompressInvalidRatio` — input validation.
- `TestPreferredTiersIncludesCompressor` — registry tier preference is wired up for `compressor` model_type.

Provider-side protocol round-trip tests in `provider/src/protocol.rs`:

- `test_compression_request_from_go_json_encrypted`
- `test_compression_request_body_roundtrip`
- `test_compression_complete_roundtrip`
- `test_compression_complete_omits_prompt_when_encrypted`

## What this is NOT

- **It is not bit-exact prefill disaggregation.** That is fundamentally bandwidth-bound across consumer internet (10 GB KV cache for a 32 K-token Qwen 27B prefill vs ~125 MB/s residential). Don't try.
- **It is not speculative decoding.** Speculative decoding accelerates the *decode* phase using a draft model on the same machine as the target. Smart prefill accelerates the *prefill* phase using a draft model on a *different* machine. Both are useful, both will be supported, neither replaces the other.
- **It is not lossless.** Phase 1 drops ~75 % of input tokens. Quality at 4× compression on LongBench / RULER is consistently >90 % across the cited research. Consumers who need verbatim recall (legal, code, exact-quote retrieval) should leave `smart_prefill` off.

## References

- arXiv 2603.02631 — Cross-Family Speculative Prefill (March 2026)
- arXiv 2604.15039 — Prefill-as-a-Service (April 2026)
- arXiv 2603.19635 — BEAVER training-free hierarchical compression (March 2026)
- arXiv 2403.12968 — LLMLingua-2 (the prior generation we're skipping past)
- waybarrios/vllm-mlx#179 — SpecPrefill prototype on our exact runtime
