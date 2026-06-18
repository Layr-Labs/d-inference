# Decode bandwidth analysis: dense-26B vs 4B-active MoE

This note derives the expected single-stream **decode** throughput (tok/s) of a
quantized model on Apple Silicon from first principles, tabulates the
expectations for a **dense-26B** read vs a **~4B-active MoE** read, and explains
how to read `darkbloom benchmark --sweep` output to decide which regime a model
is actually in.

Motivation: `gemma-4-26b-qat-4bit` and `gpt-oss-20b` are **both 4-bit** and
**both ~4B-active MoE** models, yet in production (served at batch ≈ 0) gpt-oss
decodes ~**69 tok/s** while gemma decodes only ~**21 tok/s**. 21 tok/s is the
speed of reading a **dense 26B** model per token; ~69 is the speed of reading
~4B of active weights. The hypothesis is that gemma's expert sparsity is not
being exploited at decode — it is reading (close to) the whole model every
token. This doc gives the math to confirm it and the tooling to measure it.

---

## 1. Why decode is memory-bandwidth-bound

A decode step generates **one** new token per sequence. The arithmetic is a
handful of matrix–vector products (`[1, d] × [d, n]`), which on a GPU is trivial
FLOPs but must **stream every weight it touches out of unified memory**. At
batch 1 there is no reuse of a loaded weight across tokens, so the step time is
dominated by bytes moved, not math:

```
read_bytes_per_token ≈ active_params × bytes_per_param
decode_tok_s         ≈ (peak_bandwidth_GBps × efficiency) / read_GB_per_token
```

* **`active_params`** — the weights actually read for one token.
  * **Dense** model: every weight is active ⇒ `active_params = total_params`.
  * **MoE** model: only the shared trunk (attention, norms, router, any always-on
    dense FFN, embeddings/LM head) **plus the routed top-K experts** ⇒
    `active_params ≪ total_params`.
* **`bytes_per_param`** — for 4-bit group quantization, 4 bits of payload plus a
  per-group scale (16-bit scale over a group of 64 ≈ +0.25 bit; with a
  zero-point a bit more) ⇒ **≈ 0.50–0.60 bytes/param** (we use **0.5625**, i.e.
  4.5 bits, as the midpoint). 8-bit ≈ 1.06 B/param; bf16 = 2 B/param.
* **`efficiency`** — fraction of *peak* bandwidth a real MLX decode loop sustains
  (launch latency, non-weight traffic, imperfect overlap). Empirically
  **~0.70–0.85**; we use **0.80** when interpreting a measurement.

This is implemented as pure arithmetic in
`Sources/ProviderCore/Benchmark/DecodeBandwidthModel.swift` and inverted by the
benchmark to turn a measured tok/s back into an *implied* `read_bytes_per_token`.

---

## 2. Per-token read: dense-26B vs 4B-active (4-bit)

| Regime | active params | × bytes/param | **read per token** |
|---|---|---|---|
| Dense 26B, 4-bit | 26.0 B | × 0.50–0.5625 | **~13.0–14.6 GB** |
| ~4B-active MoE, 4-bit | 4.0 B | × 0.50–0.5625 | **~2.0–2.25 GB** |
| gpt-oss-20b (~3.6B active), 4-bit | 3.6 B | × 0.5625 | **~2.0 GB** |

The dense read is **~6.5×** the 4B-active read. So at the same bandwidth a model
that exploits its sparsity should decode **~6.5× faster** than if it read its
whole 26B footprint.

---

## 3. Expected decode tok/s by bandwidth

`decode_tok_s = peak_bandwidth × 0.80 / read_GB_per_token`, using
`read = 14.6 GB` (dense-26B) and `read = 2.25 GB` (4B-active), 4-bit @ 0.5625.

| Apple Silicon (peak GB/s) | Dense-26B tok/s | 4B-active tok/s | ratio |
|---|---|---|---|
| M4 / base (~120) | ~7 | ~43 | 6.5× |
| Pro tier (~273) | **~15** | ~97 | 6.5× |
| Max tier (~400) | **~22** | **~142** | 6.5× |
| M4 Max (~546) | ~30 | ~194 | 6.5× |
| Ultra (~800) | ~44 | ~284 | 6.5× |

**Read this against production:** gemma's observed **~21 tok/s** lands right on
the **dense-26B** row for a ~400 GB/s (Max-tier) machine (~22), **not** the
~142 tok/s a 4B-active read would give. gpt-oss's **~69 tok/s** is within ~2× of
its 4B-active prediction (the gap is real shared-trunk traffic: a 128-way
router, attention sinks, and a large vocab embedding/LM-head read), i.e.
**consistent with sparse**. The conclusion the numbers force:

> **gemma is decoding as if it were a dense 26B model; its MoE sparsity is not
> translating into fewer bytes read per token.** Closing that gap is worth ~3×
> on gemma decode.

(Use *your* machine's bandwidth: `darkbloom doctor` / the sweep report prints
`hardware.memoryBandwidthGbs`. The exact tok/s scales linearly with it; the
**ratio** dense:sparse ≈ 6.5× does not.)

---

## 4. Architecture context (why this is plausible)

Read-only findings from the MLX model code (mirrored here so the numbers have a
mechanism). Both models gather routed experts sparsely — the difference is what
*else* runs every token.

* **gpt-oss = pure sparse MoE.** `MLPBlock` routes then gathers top-4 of 128
  experts and nothing else:
  `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GPTOSS.swift:289` (router →
  `mlxTopK(k=4)` → `SwiGLUSwitchGLU`), with the gather at
  `GPTOSS.swift:131`–`156` using `SwitchLinear`/`gatherQuantizedMM`.
* **gemma-4 MoE = sparse experts *plus an always-on dense FFN*.** Each MoE layer
  runs **both** a full dense MLP **and** the sparse experts and sums them:
  `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift:715`–`732`
  (`h1 = mlp(...)` dense branch + `h2 = experts(...)` sparse branch → `out = h1 + h2`).
  * The dense branch `Gemma4MLP` reads its **entire** gate/up/down every token
    (`Gemma4Text.swift:593`–`613`) and is **double-wide** on the 20 KV-shared
    layers (`Gemma4Text.swift:600`–`601`).
  * The sparse branch `Gemma4Experts` → `SwitchGLU` does gather top-K
    (`Gemma4Text.swift:564`–`589`; `SwitchLayers.swift:69`–`140`,
    `gatherQuantizedMM(..., rhsIndices:)`).

So at the source level the experts *are* gathered sparsely in both models. The
always-on dense FFN gives gemma a structurally larger always-resident read than
gpt-oss, but by itself it should not reach a full-26B read. Therefore, **if the
sweep shows gemma at the dense row, the extra bytes are coming from the routed
experts not actually being read sparsely at 4-bit decode** (e.g. the quantized
gather path materializing all experts, or a fall-back to a dense expert matmul)
— a strong, specific clue that the `gatherQuantizedMM` decode path for the
4-bit experts is the thing to fix. The benchmark localizes this empirically.

> A telling secondary symptom: the 8-bit gemma build decodes ~74 tok/s (B=1,
> mlx_lm reference) while the **4-bit** build decodes ~21 — a 4-bit model that
> is **slower** than its 8-bit sibling is backwards for a bandwidth-bound
> workload and points squarely at the 4-bit expert gather, not the dense FFN.

---

## 5. Running the sweep

The model must be downloaded locally and a Metal GPU present (Apple Silicon).
Build **release** for representative numbers (debug is several × slower):

```bash
cd provider-swift
swift build -c release
# Decode + prefill sweep for gemma, emit JSON:
.build/release/darkbloom benchmark --sweep --model gemma-4-26b > gemma_sweep.json
# Same for the sparse control:
.build/release/darkbloom benchmark --sweep --model gpt-oss-20b > gptoss_sweep.json
```

Knobs (all optional):

| flag | default | meaning |
|---|---|---|
| `--prefill-lengths` | `128,512,2048` | prompt lengths (tokens) for the prefill sweep |
| `--max-batch` | `6` | decode batch sweep runs `B = 1…N` |
| `--decode-tokens` | `64` | tokens generated per sequence in the decode sweep |
| `--decode-prompt-tokens` | `64` | prompt length per sequence in the decode sweep |

Progress prints to **stderr** (`[sweep] …`); **stdout is a single JSON document**.

---

## 6. Reading the output

```jsonc
{
  "prefill": [ { "promptTokens": 128, "prefillTokensPerSecond": 900.0, ... }, ... ],
  "decode":  [ { "batchSize": 1, "aggregateTokensPerSecond": 21.0, "perSequenceTokensPerSecond": 21.0, ... }, ... ],
  "derived": {
    "decodeTokensPerSecondAtB1": 21.0,
    "impliedReadGBPerTokenAtB1": 15.2,            // ← bytes actually moved per token
    "impliedActiveParamsAtB1": 27000000000,        // ← ≈ whole model, not ~4B
    "totalWeightGB": 14.6,
    "impliedReadFractionOfWeights": 1.04,          // ← ≈ 1.0 ⇒ reading everything
    "regime": "dense",                              // ← the verdict
    "batchScalingLinearity": 0.98,                  // ← ≈ 1.0 ⇒ dense-like scaling
    "expectedDenseDecodeTokensPerSecond": 22.0,
    "expectedFourBActiveDecodeTokensPerSecond": 142.0
  }
}
```

Primary discriminator — **`derived.impliedReadFractionOfWeights`**
(= implied per-token read ÷ total weight bytes):

* **≈ 1.0** (`regime: "dense"`) → the model reads ~its whole footprint per
  token. For an MoE this means **sparsity is not exploited** (the bug).
* **≪ 1.0** (`regime: "sparse"`) → only a slice is read per token (healthy MoE).

Corroborating signals:

* **`decodeTokensPerSecondAtB1` vs the two `expected…` references.** If B=1 ≈
  `expectedDenseDecodeTokensPerSecond` and ≪
  `expectedFourBActiveDecodeTokensPerSecond`, it is decoding dense.
* **`batchScalingLinearity`** (mean of `aggregate(B)/aggregate(1)/B`): a
  bandwidth-bound **dense** read is amortized across the batch and scales
  ~linearly (**≈ 1.0**); a **sparse** MoE pulls in additional distinct experts
  as B grows, so aggregate tok/s scales **sub-linearly** (**< 1.0**). Only
  meaningful when B=1 is already bandwidth-bound (true for ≥20B models; tiny
  models are launch-overhead-bound and can scale super-linearly instead).
* **Control run.** gpt-oss-20b on the same box should report `regime: "sparse"`.
  Gemma reporting `"dense"` while gpt-oss reports `"sparse"` **confirms the
  hypothesis** and isolates it to gemma's path.

### Caveats

* `impliedReadGBPerToken` assumes 80% of peak bandwidth; if your machine
  sustains a different fraction, the absolute GB shifts but the **fraction of
  total weights** (and hence the regime call) is robust.
* Use a **release** build; debug Swift understates tok/s several-fold.
* Prefill tok/s (`prefill[]`) is a separate, compute-heavier metric (whole prompt
  in one pass); it is reported so routing/TTFT estimators can use a *measured*
  prefill rate instead of the `decode×4` guess, but it is not the dense/sparse
  discriminator — decode is.
