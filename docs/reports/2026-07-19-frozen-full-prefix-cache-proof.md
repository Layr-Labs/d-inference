# Frozen-Full Hybrid Prefix Cache Proof

Date: 2026-07-19  
Parent base: `ac3d934a979036611b2ea3b66e51c977abfd7483`  
Engine base: `bdf4b367a3dec5a0db23797f759427965a81c0fd`

## Root cause

The old C-bound replay restored owning full-attention K/V only through C.
Sliding rows started empty at C, so early replay hidden states differed from
cold prefill. Every downstream owning full layer appended projections of those
states. Those divergent K/V entries never aged out and changed later logits.

The v0.7.11 full-replay gate was therefore necessary for the mutating replay
implementation. Changing a window count, cache threshold, block size, or other
configuration cannot remove the persistent write path.

## Exact architecture

For matched boundary M:

- R is `windowed-layer count × largest window`, clamped to M.
- C is `M - R`.
- Sliding rows start empty at C.
- Owning full rows restore exact cached arrays through M.
- A frozen row reads from C while retaining an independent immutable high-water
  M. Replay-generated full-layer K/V is ignored.
- Chunks cannot cross C or M.
- At M the full row transitions once to ordinary append.
- Preemption discards the plan and state; cancellation and shutdown release all
  rows, pins, and reservations.

DBK3 remains unchanged. The cache-layout identity is
`cbv2-frozen-full-3|native-fp|<blockSize>|<layerDigest>`.

The backend is intentionally described as native floating point, not FP16.
Real GPT-OSS full rows are FP32. The dynamic plan measured their exact aggregate
full-KV rate as 49,152 bytes per token. Claiming FP16 would under-account the
backend and contradict executable evidence. Quantized and paged hybrid rows
remain fail-cold.

## Correctness evidence

Deterministic weight-backed tests permanently cover:

- `[full, sliding, sliding, full]`, including the first persistent full-layer
  K/V divergence;
- ten prompt lengths around 256-token block boundaries;
- divergent tails;
- mixed B=2 and B=4 absolute positions;
- the actual `Gemma4TextModel` implementation with `attention_k_eq_v=true`;
- cancellation during replay, preemption rollback, exact reservation balance,
  contiguous positive admission, paged hybrid refusal, and quantized refusal;
- MTP off/on with fully accepted and fully rejected drafts and terminal
  donation.

Real downloaded weights passed:

- GPT-OSS at the original 2,817-token counterexample: old maximum absolute
  logit drift `0.20875001`; frozen logit/KV drift `0`; 64 greedy tokens and
  every post-token raw-logit vector bit-exact.
- Gemma 4 QAT at prompt lengths 26,625, 26,881, and 27,137: raw logits, owning
  full K/V, and at least 128 greedy tokens per prompt bit-exact.
- Gemma 4 QAT at 32,769 tokens: raw logits bit-exact.

Bit-exactness uses tolerance zero. The old GPT counterexample is pinned within
`0.00001` solely to make the negative canary robust to decimal formatting.

## Performance evidence

These are single local real-weight measurements, not fleet latency promises.
They isolate cold model compute from frozen replay compute.

- GPT-OSS 2,817 tokens, M=2,816, R=1,536, saved=1,280:
  cold `6.084 s`; replay `2.167 s`; `64.4%` reduction.
- GPT-OSS 4,097 tokens, M=4,096, R=1,536, saved=2,560:
  cold `5.219 s`; replay `2.098 s`; `59.8%` reduction.
- GPT-OSS 8,193 tokens, M=8,192, R=1,536, saved=6,656:
  cold `12.135 s`; replay `2.500 s`; `79.4%` reduction.
- Gemma QAT 26,625 tokens, M=26,624, R=25,600, saved=1,024:
  cold `44.357 s`; replay `58.625 s`; `32.2%` slower in this contended run.
- Gemma QAT 26,881 tokens, M=26,880, R=25,600, saved=1,280:
  cold `65.884 s`; replay `56.774 s`; `13.8%` reduction.
- Gemma QAT 27,137 tokens, M=27,136, R=25,600, saved=1,536:
  cold `54.538 s`; replay `49.187 s`; `9.8%` reduction.
- Gemma QAT 32,769 tokens, M=32,768, R=25,600, saved=7,168:
  cold `61.320 s`; replay `47.127 s`; `23.1%` reduction.

The realistic Gemma conclusion is not that every hit is large: benefit is
small and noisy just above the 25,600-token replay span, including one negative
sample under concurrent machine load, and becomes consistently material only
as the matched prefix grows beyond it. The enforced real-model performance gate
therefore targets the 32k benefit point, and production raises long-hybrid
admission to at least 1,536 saved tokens; the SSD stage gate applies to every
hit.

SSD lifecycle measurements:

- deterministic DBK3 stage p95: miss `0.512 ms`, hit `17.410 ms`, both below
  the configured `1,000 ms` gate;
- real GPT-OSS warm same-engine TTFT `3.574 s` versus cache-off `4.264 s`;
- real GPT-OSS warm-after-restart TTFT `3.928 s` versus cache-off `4.264 s`;
- 13 encrypted blocks, `163,612,332` bytes, survived restart and rehydrated;
- every staged reservation and backend reservation returned to zero in the
  lifecycle and real-model tests.

The miss-stage overhead is materially below saved prefill and does not alter
the cold model forward path.
