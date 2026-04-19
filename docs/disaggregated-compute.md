# Disaggregated Compute on Small Macs

## Why

Decoder LLMs are **memory-bandwidth bound** during decode. The prompt tokens
(prefill) compute lots of matrix-vector products in parallel; the new tokens
(decode) stream them one by one and the bottleneck is how fast the GPU can
read the model weights from unified memory. To deliver useful quality you
need a model that fits in RAM — so a 16 GB Air or base Mini can't run a
quality LLM and was previously useless to the network.

But not every workload is memory-bandwidth bound. **Embeddings, reranking,
and (future) speculative-decode draft tokens** are all *compute bound*: the
model is small (100 MB – 2 GB), the GPU is the bottleneck, and the response
is tiny. A 16 GB Mac is genuinely fast at them — and the work is plentiful
because every retrieval-augmented chatbot, search box, and recommender
needs them.

This is the disaggregated-compute layer. Low-RAM providers earn revenue,
big-RAM providers stay free for decode, the consumer gets cheaper / lower
latency embeddings.

## How it routes

The coordinator now classifies every provider on register into a tier:

| Tier | Memory | Workloads |
|------|--------|-----------|
| `tiny` | ≤ 16 GB | embeddings, rerank |
| `small` | 18–24 GB | embeddings, rerank, ≤ 7 B chat |
| `standard` | ≥ 32 GB | full text/image/STT decode |

The catalog now stores `model_type` for each model. When a request comes in
for an `embedding` or `rerank` model, the scheduler applies a 50 000 ms
**tier-mismatch penalty** to standard-tier candidates, so the smallest
capable provider always wins routing — but if every small provider is busy,
work spills up to bigger machines instead of failing.

See:
- `coordinator/internal/registry/registry.go` — `ClassifyTier`,
  `PreferredTiersForModelType`
- `coordinator/internal/registry/scheduler.go` — `tierMismatchPenaltyMs`
- `coordinator/internal/api/embeddings.go` — request handlers

## Wire protocol

Two new request types and two new response types share the same E2E
encryption layer as chat completions (NaCl box, X25519 + XSalsa20-Poly1305).
Cross-language symmetry between Go and Rust is enforced by the round-trip
tests in `coordinator/internal/protocol/messages_test.go` and
`provider/src/protocol.rs`.

| Type | Direction | Purpose |
|------|-----------|---------|
| `embedding_request` | C → P | OpenAI-shaped embed body |
| `embedding_complete` | P → C | vectors + usage |
| `rerank_request` | C → P | Cohere-shaped rerank body |
| `rerank_complete` | P → C | scored results + usage |

Vectors travel **inline** (not over HTTP like images) — typical payloads
are ≤ 64 inputs × 1024 dims × 4 bytes = 256 KB, comfortably under the
10 MB WebSocket frame limit.

## API surface

OpenAI / Cohere shape, served at `https://api.darkbloom.dev`:

```bash
curl https://api.darkbloom.dev/v1/embeddings \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"mlx-community/bge-m3","input":["hello","world"]}'

curl https://api.darkbloom.dev/v1/rerank \
  -H "Authorization: Bearer $KEY" \
  -d '{"model":"mlx-community/bge-reranker-v2-m3",
       "query":"what is X?",
       "documents":["A","X is Y"],
       "top_n":1}'
```

Response shape mirrors OpenAI / Cohere exactly, so existing LangChain /
LlamaIndex / Haystack code drops in unchanged.

## Models in the catalog

Seeded by `coordinator/cmd/coordinator/main.go: seedModelCatalog`:

| ID | Type | Size | Min RAM |
|----|------|------|---------|
| `mlx-community/bge-m3` | embedding | 1.2 GB | 8 GB |
| `mlx-community/Qwen3-Embedding-0.6B` | embedding | 0.7 GB | 8 GB |
| `mlx-community/Qwen3-Embedding-4B` | embedding | 4.5 GB | 16 GB |
| `mlx-community/mxbai-embed-large-v1` | embedding | 0.7 GB | 8 GB |
| `mlx-community/bge-reranker-v2-m3` | rerank | 1.2 GB | 8 GB |
| `mlx-community/Qwen3-Reranker-0.6B` | rerank | 0.7 GB | 8 GB |

## Pricing

Per `coordinator/internal/payments/pricing.go`:

| Model class | Default rate | Cheapest hosted competitor |
|-------------|--------------|----------------------------|
| Embeddings | $0.005 / 1 M tokens | Together $0.008 / 1 M |
| Reranking  | $0.010 / 1 M tokens | Cohere $0.05 per 1k pairs |

Same 95 % provider / 5 % platform split as chat completions.

## Provider sidecar

The provider expects a local HTTP service on `127.0.0.1:$EIGENINFERENCE_EMBEDDING_PORT`
exposing OpenAI-shaped `/v1/embeddings` and Cohere-shaped `/v1/rerank`. The
default port is `image_port + 1` (deterministic so the launcher and the
proxy agree without IPC).

If the sidecar isn't running, embedding requests fail with `connect refused`
and the coordinator routes to another small-tier provider — no special
"embedding capability" advertisement is needed beyond the model being in
the provider's served list.

A first-party sidecar based on `mlx_embeddings` will ship with the next
provider bundle. Running it manually for now:

```bash
pip install mlx_embeddings
EIGENINFERENCE_EMBEDDING_PORT=8086 \
  python -m mlx_embeddings.server --port 8086 --model mlx-community/bge-m3
```

## Testing

Coordinator-side end-to-end tests live in
`coordinator/internal/api/embeddings_test.go`:

- `TestEmbeddingsE2E` — full round-trip: register a 16 GB tiny provider,
  POST `/v1/embeddings`, decrypt, return vector, confirm OpenAI-shaped
  response and persisted usage.
- `TestRerankE2E` — same flow for `/v1/rerank` including `top_n` trim.
- `TestEmbeddingsRejectsNonCatalogModel` — catalog gate.

Routing tests live in `coordinator/internal/registry/tier_test.go`:

- `TestEmbeddingRoutingPrefersSmallTier` — tiny provider wins over a
  beefy 128 GB machine.
- `TestEmbeddingFallsBackToBigWhenSmallExhausted` — graceful fallback.
- `TestTextRoutingHasNoTierPreference` — text decode still routes on perf.

Provider protocol round-trip tests live alongside the chat protocol tests
in `provider/src/protocol.rs`.

## Future: speculative decoding draft offload

The same protocol scaffolding (small request, small response, compute
bound) makes speculative decoding a natural next step. A tiny-tier
provider runs the draft model and proposes K tokens; the standard-tier
provider running the big model verifies them in parallel. Quality is
mathematically identical to standard decode (rejection sampling), and the
big provider's GPU spends more time on the parallelizable verification
step than on the serial-token draft path. That work is left as a follow-up
once the embedding / rerank traffic establishes the small-tier fleet.
