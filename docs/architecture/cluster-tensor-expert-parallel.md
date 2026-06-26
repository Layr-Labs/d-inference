# Tensor & Expert Parallelism for the Darkbloom Cluster

**Status:** design / implementation-ready
**Scope:** replace the sequential pipeline-parallel decode loop (`ClusterPipeline.swift`) with tensor parallelism (TP) for dense models (Mistral) and expert parallelism (EP) for MoE models (gpt-oss), on a 2-node co-located Apple Silicon cluster.
**Audience:** whoever implements `ClusterTensorParallel.swift` + the `mlx-swift-lm` fork shard changes.

All file paths, function names, and config values below were read from the live repo at `/Users/tarasshchybovyk/Eigen/d-inference`. Hardware target: `mac-32` = M4 / 32 GB (rank 0, head), `mac-24` = M4 Pro / 24 GB (rank 1, tail). Link is either Wi-Fi (~42 ms RTT) or Thunderbolt-IP (~1 ms RTT). Ring transport is TCP. (RDMA/`jaccl` is **not** forbidden by the trust policy — the coordinator accepts `rdma_disabled: false` providers under a "registered-buffer RDMA policy" and only requires the status be *reported*, `api/provider.go:1184-1200`; the security boundary is the signed runtime's IOMMU buffer-registration discipline, not a blanket ban. We use the TCP ring today because it's what's wired, not for policy reasons — JACCL is a viable future transport.) Ring collectives run on the **CPU stream** (`communication_stream` forces `Device::cpu`, `ring.cpp:471`).

---

## 0. Visual overview — three topologies

Three ways to split one model across the two-Mac cluster, drawn as both the
**logical split** (top) and the **physical chain a single token traverses**
(bottom). The composition shown is an 80-layer model (head = M4 Pro layers 0–43,
tail = M4 base layers 44–79) for the pipeline diagram; the TP diagrams split
*within* every layer instead.

> The numbers in the RDMA diagram (~0.25 ms/reduce, ~40 tok/s) are the **projected**
> target from the §1 comms-floor model — **not measured**, because Apple
> RDMA-over-Thunderbolt (JACCL) needs **TB5 on both ends** and the base M4 is TB4
> (0 RDMA devices vs the M4 Pro's 3). The CPU-stream ring numbers (~1 ms/reduce,
> ~12 tok/s) *are* measured (`comms-bench`). See `jaccl-rdma-readiness.md`.

### 0.1 Pipeline parallelism (layer split) — what we run today

```
                        ONE TOKEN, BATCH=1  —  PIPELINE PARALLELISM (layer split)
 ┌─────────────────────────────────────────┐        ┌─────────────────────────────────────────┐
 │  HEAD  ·  M4 Pro                          │        │  TAIL  ·  M4 base                         │
 │  rank 0                                   │  ring  │  rank 1                                   │
 │  layers  0 ── 43   (44 layers)            │  hop   │  layers 44 ── 79   (36 layers)            │
 │  embed + first half of the transformer    │═══════▶│  second half + norm + lm_head + argMax    │
 └─────────────────────────────────────────┘        └─────────────────────────────────────────┘
        │  activation [1, hidden] bf16,                        │  next-token id
        │  AEAD-sealed, sent over TCP                          │  sent back via all_gather
        └──────────────────────────────────────────────◀──────┘


 PHYSICAL CHAIN  (what actually executes, left → right in time)

  HEAD (M4 Pro)                                                  TAIL (M4 base)
  ┌──────┬─────────────────┬──────────────────┐   wire   ┌──────────────────┬─────────────────┬──────┐
  │ CPU  │      GPU         │       CPU        │  ~0.03ms │       CPU         │      GPU        │ CPU  │
  ├──────┼─────────────────┼──────────────────┤ ════════ ├──────────────────┼─────────────────┼──────┤
  │embed │ run layers 0-43 │ encode bf16       │ socket   │ recv from socket │ run layers 44-79│ read │
  │tokens│ (GPU compute)   │ AEAD seal         │ ──────▶  │ AEAD open         │ + norm+lm_head  │ token│
  │      │                 │ →i32 → send()     │  TCP     │ decode → MLXArray │ + argMax (GPU)  │ back │
  └──────┴─────────────────┴──────────────────┘          └──────────────────┴─────────────────┴──────┘

      CPU → GPU → CPU → socket ───▶ socket → CPU → GPU → CPU → (all_gather: token id back to head)

  while HEAD's GPU runs layers 0-43,  TAIL sits idle in recv_wait  ◀─┐
  while TAIL's GPU runs layers 44-79, HEAD sits idle in all_gather    │  ← the PIPELINE BUBBLE
                                                                       │    (the two GPUs never
  critical path = head_GPU + (CPU+socket ~1ms) + tail_GPU ───────────┘     overlap at batch=1)
```

**One ring hop per token; the two GPUs run sequentially (the bubble).** CPU
crypto/serialize (~0.3 ms) and the socket hop (~0.03 ms) are negligible — ~95% of
the token is sequential GPU compute. The split makes the model **fit**, not **fast**.

### 0.2 Tensor parallelism over the CPU-stream ring (today's transport)

```
                        ONE TOKEN, BATCH=1  —  TENSOR PARALLELISM (within-layer split)
 ┌─────────────────────────────────────────┐        ┌─────────────────────────────────────────┐
 │  M4 Pro  ·  rank 0                        │◀══════▶│  M4 base  ·  rank 1                       │
 │  ALL layers 0 ── 79                       │ all-   │  ALL layers 0 ── 79                       │
 │  but only HALF of each layer:             │ reduce │  but only HALF of each layer:             │
 │   · attention heads  0 ── (n/2)           │  ↕↕↕   │   · attention heads (n/2) ── n            │
 │   · MLP columns      left half            │  every │   · MLP columns      right half           │
 └─────────────────────────────────────────┘ layer  └─────────────────────────────────────────┘
   BOTH GPUs compute EVERY layer, in parallel, on their slice of the weights.
   Twice per layer they must SUM partials across the wire (all-reduce) to stay in sync.


 PHYSICAL CHAIN  (per layer — repeats 80×, both nodes lockstep)

  M4 Pro (rank 0)                                            M4 base (rank 1)
  ┌─────────────────┬──────┬────────┐                        ┌────────┬──────┬─────────────────┐
  │      GPU        │ CPU  │ socket │  ═══ all-reduce ═══     │ socket │ CPU  │      GPU        │
  ├─────────────────┼──────┼────────┤   (sum + broadcast)    ├────────┼──────┼─────────────────┤
  │ attn on heads   │ copy │ send   │ ◀══════════════════════│ send   │ copy │ attn on heads   │
  │  0..n/2         │ GPU→ │ partial│ ──────────────────────▶│ partial│ →GPU │  n/2..n         │
  │                 │ CPU  │        │   each gets the SUM     │        │ CPU  │                 │
  └─────────────────┴──────┴────────┘                        └────────┴──────┴─────────────────┘
        │  ... then MLP, then a SECOND all-reduce, then next layer ...  │
        ▼                                                                ▼
  ┌─────────────────┬──────┬────────┐                        ┌────────┬──────┬─────────────────┐
  │ MLP left cols   │ GPU→ │ send   │ ◀══════ all-reduce ════▶│ send   │ →GPU │ MLP right cols  │
  └─────────────────┴──────┴────────┘                        └────────┴──────┴─────────────────┘

  PER LAYER:  GPU → CPU → socket ──▶ socket → CPU → (sum) → GPU      ... ×2 (after attn, after MLP)
  PER TOKEN:  80 layers × 2 reduces = 160 collectives, STRICTLY SEQUENTIAL
              (layer N+1 cannot start until layer N's all-reduce returns)

  NO bubble — both GPUs busy.  Instead: a COLLECTIVE between every half-layer.
  Each reduce ~1.0 ms (dominated by GPU→CPU crossing + .eval() barrier, NOT the ~20 KB payload).
  160 × ~1 ms sequential ⇒ batch-1 TP floored at ~12 tok/s — no better than pipeline.
```

**No bubble (both GPUs busy), but a collective between every half-layer.** At
batch=1 this is **latency-bound**: ~1 ms/reduce × 160 sequential reduces ⇒ ~12 tok/s.
The win is **throughput with batching** (the comms floor is ~fixed per step
regardless of batch size), not single-stream latency — see §1.

### 0.3 Tensor parallelism over RDMA (JACCL — projected, needs TB5 on both ends)

```
                  ONE TOKEN, BATCH=1  —  TENSOR PARALLELISM over RDMA
 ┌─────────────────────────────────────────┐        ┌─────────────────────────────────────────┐
 │  M4 Pro  ·  rank 0                        │◀══════▶│  M4 base  ·  rank 1                       │
 │  ALL layers 0 ── 79, HALF of each:        │  RDMA  │  ALL layers 0 ── 79, HALF of each:        │
 │   · attn heads 0..n/2                     │ all-   │   · attn heads n/2..n                     │
 │   · MLP left columns                      │ reduce │   · MLP right columns                     │
 └─────────────────────────────────────────┘        └─────────────────────────────────────────┘


 PHYSICAL CHAIN — CPU-stream ring (§0.2)               vs           RDMA (this)

  per reduce, RING:                                      per reduce, RDMA:
  ┌─────┐  ┌─────┐  ┌──────┐                              ┌─────┐                  ┌─────┐
  │ GPU │─▶│ CPU │─▶│socket│══▶ ...                        │ GPU │ ════ NIC DMAs ══▶ │ GPU │
  └─────┘  └─────┘  └──────┘                              └─────┘  reads/writes     └─────┘
   compute   copy   syscall                                compute  memory directly  compute
   + .eval() barrier stalls                                NIC moves bytes; no CPU copy,
   ~1.0 ms / reduce                                        no socket syscall, no host barrier
                                                           ~0.2–0.3 ms / reduce


 PER LAYER (RDMA), both nodes lockstep, NO CPU in the DATA path:

  M4 Pro (rank 0)                                          M4 base (rank 1)
  ┌─────────────────┐                                      ┌─────────────────┐
  │ GPU: attn heads │═══════════ RDMA all-reduce ═════════▶│ GPU: attn heads │
  │      0..n/2     │◀════ NIC ↔ NIC, memory-to-memory ════│      n/2..n     │
  └─────────────────┘    (sum partials, both get result)   └─────────────────┘
  ┌─────────────────┐                                      ┌─────────────────┐
  │ GPU: MLP left   │═══════════ RDMA all-reduce ═════════▶│ GPU: MLP right  │
  └─────────────────┘◀═════════════════════════════════════└─────────────────┘

  PER REDUCE:  GPU ═══ NIC (DMA, no CPU copy) ═══▶ GPU   ← CPU copy / socket / eval-barrier GONE
  PER TOKEN:   still 160 collectives, still strictly sequential — but each ~3-4× cheaper
               160 × ~0.25 ms ⇒ batch-1 TP ceiling lifts to ~40+ tok/s (PROJECTED, not measured)
```

**RDMA deletes the per-reduce data-path crossing** (GPU→CPU copy, socket syscall,
`.eval()` host barrier) — the NIC moves bytes memory-to-memory. The CPU still
*launches* the collective and issues the DMA descriptor (control), so it isn't
literally zero-CPU; it just no longer copies the bytes or blocks on a syscall per
reduce. The **160-reduces-strictly-sequential** structure is unchanged — RDMA makes
each reduce ~3-4× cheaper (~1 ms → ~0.25 ms), it does **not** parallelize them. So
batch-1 TP stays latency-bound, just at a far higher ceiling (~12 → ~40+ tok/s).

| Per all-reduce | CPU-stream ring (measured) | RDMA (projected) |
|---|---|---|
| GPU→CPU copy (host staging) | present | gone — NIC DMAs from memory |
| socket `send`/`recv` syscall | present | gone — NIC↔NIC directly |
| `.eval()` host barrier | present | gone — stays on GPU stream |
| **cost / reduce** | **~1.0 ms** | **~0.2–0.3 ms** |
| collectives / token | 160 (2×80) | 160 (2×80) — *unchanged* |
| **batch-1 TP ceiling** | **~12 tok/s** | **~40+ tok/s** |

---

## 1. Why TP/EP beats pipeline here

### The current loop (`ClusterPipeline.generate`, ClusterPipeline.swift:60)

Each rank owns a **contiguous layer interval** (`LayerPartition.partition`). Per decode step:

1. head embeds (`shard.embed`), peers `recvLike` the sealed hidden state from `rank-1` (line 97).
2. every rank runs **only its own layers** (`shard.runOwnedLayers`, line 106).
3. non-tail `send`s the sealed result to `rank+1` (line 115); tail samples (`projectToLogits` + `argMax`, line 124).
4. every rank `allGather`s the sampled token (line 131).

This is **sequential**: while rank 0 computes layers `[0, k)`, rank 1 is idle waiting on `recvLike`; while rank 1 computes `[k, N)`, rank 0 is idle. At batch=1 the two GPUs never compute at the same time. The split only makes the model **fit**; it does not make it **fast**. Measured ~9–12 tok/s on gpt-oss-20b — roughly half the single-GPU compute is wasted as idle, on top of the per-token wire hop.

### Comms vs compute, quantified per token

Let `H` = hidden_size, `L` = number of transformer layers, activation dtype = bf16 (2 bytes), batch=1, decode width=1 (one token/step).

**Pipeline (current):** exactly **one** inter-node hop per token (one `send`/`recvLike` pair on the single 2-node boundary; the tail-token `allGather` is 4 bytes, negligible).
- Bytes on the wire per token ≈ `H * 2` + AEAD/codec overhead. From `ClusterPipeline.sealedLen` (line 51): `14 + width*H*2 + 28`.
- Mistral (`H=5120`): `14 + 5120*2 + 28 = 10,282` bytes ≈ **10 KB / token**, one direction, once.
- gpt-oss (`H=2880`): `14 + 2880*2 + 28 = 5,802` bytes ≈ **5.7 KB / token**.
- **Latency cost:** 1 RTT-ish per token (one ordered hop). At 42 ms Wi-Fi that's a hard floor of ~24 tok/s *before any compute*; at 1 ms TB it's ~1000 tok/s floor. The reason pipeline is "right for geo-distributed" is exactly this single-hop minimal-comms property.

**Tensor parallelism (TP):** the layer stack is split *within* each layer across both nodes; both compute every layer concurrently on half the heads / half the MLP. Each layer needs **2 all-reduces** of the full hidden vector (after attention output projection, after MLP down projection — see §2).
- Collectives per token = `2 * L`.
- Per-collective payload (the ring `all_sum` moves ~`2*(p-1)/p * nbytes` end-to-end for `p` ranks; for `p=2` that's `~1x nbytes` reduce-scatter + `~1x` all-gather): one all-reduce of an `H`-vector bf16 ≈ `H*2` bytes per direction.
- Mistral: `2 * 40 = 80` all-reduces/token, each `5120*2 = 10,240` bytes ⇒ ~**0.82 MB/token** moved (plus AEAD framing, see §2.3).
- gpt-oss: `2 * 24 = 48` all-reduces/token, each `2880*2 = 5,760` bytes ⇒ ~**0.28 MB/token** (attention only; MoE handled by EP, see §3).
- **Latency cost:** `2*L` *sequential* collectives per token, because layer `i+1` depends on layer `i`'s all-reduce. This is the killer over Wi-Fi: `80 * 42 ms = 3.4 s/token` ⇒ **0.3 tok/s. TP over Wi-Fi is a non-starter.** Over Thunderbolt: `80 * ~1 ms = ~80 ms` of comms latency/token ⇒ comms allows ~12 tok/s *ceiling from latency alone* — still tight. The win comes from compute parallelism + TCP_NODELAY pipelining (`ring.cpp:441`); the all-reduces for independent quantities within a layer can overlap, and the dominant cost becomes per-collective *fixed overhead*, not bandwidth (bandwidth is trivial: 0.82 MB/token * 12 tok/s ≈ 10 MB/s, far under even Wi-Fi).

**Expert parallelism (EP):** for the MoE MLP, only the **top-k experts' worth** of each token's hidden vector moves, via all-to-all dispatch + combine (§3).
- gpt-oss: `experts_per_token=4`, `num_local_experts=32`, `H=2880`. Per MoE layer, per token: dispatch up to `k=4` hidden vectors out (to whichever node holds each selected expert) and combine them back ⇒ `2` all-to-all rounds, each moving at most `k*H*2 = 4*2880*2 = 23 KB` worth, but in practice only the fraction of the `k` experts that live on the *remote* node. With balanced 16/16 placement, ~half of 4 experts are remote ⇒ ~`2*2*H*2 = 11.5 KB/token/layer` across `24` layers ⇒ ~**0.28 MB/token** for MoE comms, on top of TP'd attention.
- **Latency cost:** `2` all-to-all rounds * `24` layers = `48` sequential collectives/token, same order as TP attention. Same conclusion: **Thunderbolt-only.**

### Verdict

| Strategy | Comms/token | Sequential collectives/token | Wi-Fi (42ms) | Thunderbolt (1ms) | Both GPUs busy? |
|---|---|---|---|---|---|
| Pipeline (current) | ~5–10 KB | 1 hop + 1 tiny gather | viable (~9–12 tok/s, measured) | viable | **No** (sequential) |
| TP (Mistral dense) | ~0.82 MB | `2L = 80` | **no** (~0.3 tok/s) | yes | **Yes** |
| TP attn + EP MoE (gpt-oss) | ~0.55 MB | `2L + 2L = 96` | **no** | yes | **Yes** |

**Conclusion:** TP/EP are the right design *only over Thunderbolt*. The implementation must keep `ClusterPipeline.swift` as the fallback for the Wi-Fi / >2-node / geo-distributed case, and select TP/EP when the link is the low-latency local TB path. Pipeline minimizes comms (1 hop); TP/EP maximize parallel compute (`2L` hops) — the trade is only worth it when per-hop latency is ~1 ms.

---

## 2. Tensor parallelism for a dense layer (Mistral)

Mistral-24b config (`~/m/mistral-24b-8bit/config.json`): `hidden_size=5120`, `intermediate_size=32768`, `num_attention_heads=32`, `num_key_value_heads=8`, `head_dim=128`, `num_hidden_layers=40`, `vocab_size=131072`.

With `p=2` ranks, each rank holds **half** the heads and **half** the MLP intermediate, and computes its half every layer. This is the standard Megatron-LM partition.

### 2.1 Attention sharding (split heads)

- `num_attention_heads=32` ⇒ 16 heads/rank. `num_key_value_heads=8` (GQA) ⇒ 4 KV heads/rank. Both divide evenly by 2 — good (a node holding an odd split would need padding; not needed here).
- **Column-parallel QKV:** each rank loads only its slice of `q_proj`, `k_proj`, `v_proj` (rows for its heads). Rank 0 holds heads `[0,16)`, rank 1 holds `[16,32)`. Each computes attention for its own heads locally — **no communication inside attention**, because each head is independent and each rank keeps the KV cache only for its own heads.
- **Row-parallel output projection (`o_proj`):** `o_proj` is `[H, H] = [5120, 5120]`, split by **input rows**: rank `r` holds `o_proj[:, r*2560:(r+1)*2560]` (the columns matching its head outputs). Each rank produces a **partial** `[1, 1, 5120]` sum over its heads. The two partials must be summed:
  - **`all_reduce(sum)` #1** goes right after `o_proj`, before the residual add and the post-attention norm. Each rank contributes its `[1,1,5120]` partial; output is the full attention result on both ranks.

### 2.2 MLP sharding (column-parallel up/gate, row-parallel down)

Mistral MLP is SwiGLU: `down( silu(gate(x)) * up(x) )`, `gate`/`up` are `[I, H] = [32768, 5120]`, `down` is `[H, I] = [5120, 32768]`.

- **Column-parallel `gate` and `up`:** rank `r` holds rows `[r*16384, (r+1)*16384)` of `gate` and `up` ⇒ produces a `[1,1,16384]` slice of the intermediate. `silu` and the elementwise `*` are local (no cross-talk between intermediate channels). **No communication mid-MLP.**
- **Row-parallel `down`:** rank `r` holds columns `[r*16384, (r+1)*16384)` of `down` ⇒ each produces a **partial** `[1,1,5120]`.
  - **`all_reduce(sum)` #2** goes right after `down`, before the residual add. Output is the full MLP result on both ranks.

So per layer: **exactly 2 all-reduces**, both summing an `H`-wide vector. Norms (RMSNorm) and residual adds run identically (redundantly) on both ranks on the full hidden vector — cheap, avoids extra comms. The embedding (head only today) becomes **replicated**: both ranks embed and both run `lm_head`, OR keep head/tail roles and `all_gather` the final hidden before logits. Simplest: replicate embed + final-norm + `lm_head` on both ranks (vocab 131072 * 5120 is large but quantized 8-bit, and it removes a hop). **Decision:** replicate embed and lm_head on both ranks; sampling is then identical on both ⇒ the per-token `all_gather` of the sampled token (ClusterPipeline.swift:131) is no longer needed for correctness, but keep a 4-byte token `all_gather` as a cheap consensus/consistency check.

### 2.3 What's communicated (shape/dtype/bytes)

Per all-reduce, Mistral:
- Tensor `[1, 1, 5120]`, dtype bf16 ⇒ payload `5120 * 2 = 10,240` bytes.
- The ring `all_sum` (reduce-scatter + all-gather, `ring.cpp:590` `all_reduce` → `all_reduce_impl` line 665) moves ~`2*(p-1)/p` of that across the wire; for `p=2`, ~`1.0x` reduce + `1.0x` gather ≈ 20 KB total wire traffic per all-reduce.
- `2 * 40 = 80` all-reduces/token ⇒ ~0.82 MB/token of payload, ~1.6 MB/token on the wire. Trivial bandwidth; the cost is the `80` sequential CPU-stream round trips.

### 2.4 Encryption: sealing a symmetric all-reduce

This is the subtle part. Today's crypto (`ClusterLinkCrypto.swift`) is **directional**: `ClusterSealingChannel` seals toward `nextRank`, `ClusterOpeningChannel` opens from `prevRank`, with **separate keys per direction** (`ClusterSessionKeys.directionalKey`, "A>B" vs "B>A") and a **monotonic counter nonce** per channel. The pipeline hop is one-directional, so this maps cleanly: one seal, one open.

An **all-reduce is symmetric** — both ranks send *and* receive in the same op. The ring `all_sum` does it as internal `send`/`recv` of raw bytes; it cannot itself encrypt. Two options:

**Option A (recommended for v1): encrypt the operands, do a plaintext-on-the-wire-of-ciphertext "reduce" by emulating all-reduce in Swift as send+recv+local-add.** Because `p=2`, an all-reduce is just: "I send my partial to the peer, I receive the peer's partial, I add them." That is **one directional send + one directional recv** — *exactly* the primitive the existing crypto already secures. So for 2 nodes we do NOT call the ring's `all_sum`; we do:

```
// pseudo, per all-reduce point, rank r, peer = 1 - r
let sealed = sealCh.seal(ActivationCodec.encode(myPartial.asType(.bfloat16)), context: ctx_out)   // toward peer
let dep = group.send(toI32(sealed), to: peer); dep.eval()
let cipher = group.recvLike(template, from: peer)                                                  // from peer
let peerPartial = ActivationCodec.decode(openCh.open(toBytes(cipher), context: ctx_in))
let reduced = myPartial + peerPartial      // local add on GPU
```

This keeps the **existing directional-key, monotonic-nonce discipline untouched** — every collective is still one seal (counter++ on the send channel) and one open (expected-counter++ on the recv channel). The AAD `layerRange` field (currently `"hop-N"`) becomes the all-reduce site identifier, e.g. `"tp-attn-L17"` / `"tp-mlp-L17"`, so a frame can't be replayed across layers or across the two reduce points. **Nonce safety is preserved because send and recv use different keys and each has its own monotonic counter.** The send/recv on a 2-node ring are direct-neighbor (the only kind the ring allows, `ring.cpp:539/560`), and with `size_=2` left==right so it works (note the ring's own comment at `recv`, line ~561, about 2-node left/right aliasing).

Cost: `2L` * (1 seal + 1 open + 1 send + 1 recv + 1 GPU add). For Mistral that's 80 seal/open pairs/token. AEAD on a 10 KB frame is ~microseconds (ChaChaPoly is fast); the encode/decode (`ActivationCodec`) copies the tensor out of and into MLX each time — see Risks §7.

**Option B (later, for `p>2`): use the ring's native `all_sum` and protect the channel out-of-band.** A true `all_sum` reduces over the wire and we can't insert AEAD per hop without forking the ring's reduce loop. For `p>2` you'd need a symmetric group key + per-(rank,seq) nonce derivation, or to fork `ring.cpp`'s `all_reduce_impl` to seal/open each segment. Out of scope for the 2-node target. **For 2 nodes, Option A is strictly simpler and reuses verified crypto — use it.**

> Implication: the "all-reduce" we ship for 2 nodes is **send+recv+add**, not the ring's `all_sum`. This is correct and is the minimal change. We only need the ring's real `all_sum` if/when the cluster grows past 2 nodes, at which point we revisit Option B.

---

## 3. Expert parallelism for the MoE layer (gpt-oss)

gpt-oss-20b config (`~/m/gptoss-20b-q8/config.json`): `model_type=gpt_oss`, `hidden_size=2880`, `intermediate_size=2880`, `num_hidden_layers=24`, `num_local_experts=32`, `num_experts_per_tok=4` (== `experts_per_token`), `num_attention_heads=64`, `num_key_value_heads=8`, `head_dim=64`. Attention is alternating `sliding_attention`/`full_attention` (the `layer_types` array). Experts are MXFP4-quantized (4-bit), attention proj are 8-bit affine (from the `quantization` block).

**Attention** in gpt-oss is TP'd exactly as in §2 (64 heads → 32/rank, 8 KV heads → 4/rank, both divide by 2; one all-reduce after `o_proj`). The MoE block replaces the dense MLP and uses **EP**.

### 3.1 Expert placement (weighted 32:24)

32 experts, 2 nodes. Memory weighting by the 32 GB / 24 GB split (the same `LayerPartition` philosophy, but over experts not layers). Total weight 56 ⇒ mac-32 share `32/56 * 32 ≈ 18.3`, mac-24 share `24/56 * 32 ≈ 13.7`. Round to **mac-32 (rank0): experts [0,18), mac-24 (rank1): experts [18,32)**.

But router skew matters more than memory here (see §3.4). Each expert in gpt-oss is a small SwiGLU on `intermediate_size=2880` (== hidden), MXFP4 — roughly `3 * 2880 * 2880 * 0.5 bytes ≈ 12.4 MB/expert/layer` * 24 layers ≈ 300 MB/expert total. 18 vs 14 experts ≈ 5.3 GB vs 4.1 GB just for expert weights — well within budget; see §7 for the full KV+weights fit check. **Placement is per-layer-uniform** (expert `e` lives on the same node in every layer) so the dispatch routing table is computed once.

### 3.2 The MoE forward with all-to-all

Per MoE layer, both ranks already hold the **full** post-attention hidden state (it was all-reduced in §2.1). The router (`gate`, a `[32, 2880]` projection) is **replicated** on both ranks — cheap, and avoids a comms round to share routing decisions: both ranks compute the identical top-4 expert ids + weights for the (single) token.

Then:

1. **Dispatch (all-to-all #1):** for each selected expert `e`, the token's hidden vector must be at the node owning `e`. Both ranks know the routing table, so each rank:
   - keeps the tokens routed to its **local** experts (no wire),
   - **sends** to the peer the token's hidden vector for each expert routed to the **remote** node.
   For batch=1 / width=1, "tokens" = the one token, replicated to ≤ `k=4` experts. Concretely rank `r` sends the hidden vector once per remote-expert selection (dedup: send the `[1,1,2880]` vector at most once to the peer if *any* of the token's experts are remote, plus the list of which remote experts to run — the peer runs them and returns weighted partials).
2. **Compute:** each rank runs its locally-owned selected experts on the token (`silu(gate·x)*up(x)` then `down`), scales each by its router weight.
3. **Combine (all-to-all #2):** each rank sends back the **weighted expert outputs** for experts it ran on behalf of the peer; each rank sums the contributions (local + received) into the final `[1,1,2880]` MoE output. Then residual add (local).

For 2 nodes, all-to-all degenerates to the **same send+recv pair** as §2.4 — there is exactly one peer. So EP needs **no new collective**: it's `recvLike`/`send` of (a) the dispatched hidden + expert-id list and (b) the combined weighted partials, sealed with the existing directional channels. AAD `layerRange` = `"ep-dispatch-L{n}"` / `"ep-combine-L{n}"`.

### 3.3 Communication volume per token (gpt-oss)

- Dispatch: at most one `[1,1,2880]` bf16 vector (5,760 B payload) + a tiny expert-id/weight list, sent to the peer **only if** the token routes ≥1 expert remotely. With balanced placement and uniform routing, P(all 4 experts local) is small, so ~1 hidden vector out per layer.
- Combine: peer returns its weighted partial `[1,1,2880]` (5,760 B) back.
- ⇒ ~`2 * 5,760 ≈ 11.5 KB/token/MoE-layer`, `* 24 layers ≈ 0.28 MB/token`, plus the attention all-reduce (§2.3) `2880*2*2*24 ≈ 0.28 MB/token`. Total gpt-oss ≈ **0.55 MB/token**.
- Sequential collectives: attention `1 all-reduce *24` + MoE `2 *24` = **72 sequential send/recv rounds/token**. TB-only, as in §1.

### 3.4 Load imbalance

The router can send most/all of the token's top-4 to experts on **one** node, leaving the other idle — the classic MoE imbalance, made worse at batch=1 (no averaging across a batch). Mitigations, in order of effort:

1. **Accept it for batch=1.** With width=1 the absolute compute per expert is tiny; the bottleneck is comms latency, not expert FLOPs. Imbalance costs little when each "compute" is one token through one small MLP.
2. **Interleave expert placement** rather than contiguous: assign experts round-robin (`e % 2`, weighted to put the extra 4 on mac-32) so that any given top-4 is statistically split ~2/2 across nodes. This minimizes the chance that all 4 land on one node and balances the *expected* per-node expert count per token. **Recommended.**
3. **Batched decode (continuous batching):** when the provider batches `B` concurrent requests (the existing `BatchedEngine` path), tokens-to-experts averages out across the batch and both nodes stay busy. This is the real imbalance fix and aligns with the project's continuous-batching design (see CLAUDE.md "Continuous batching"). EP should be designed to carry a `[B, 1, H]` activation, not just `[1,1,H]`, so dispatch groups tokens by destination node and sends one batched frame per direction per round.

**Decision:** ship interleaved placement (#2) + design the dispatch/combine to handle a batch dim (#3), even if v1 runs batch=1.

---

## 4. Collective gap analysis (ring backend)

Read from `libs/mlx-swift/Source/Cmlx/mlx/mlx/distributed/ring/ring.cpp` and the C API `mlx-c/mlx/c/distributed.h`.

### What the forked ring backend implements today (`RingGroup`, ring.cpp:387)

| Collective | ring.cpp | C API (`distributed.h`) | Swift wrapper (`MLXDistributed.swift`) |
|---|---|---|---|
| `send` (direct neighbor only) | ✅ line 539 | ✅ `mlx_distributed_send` | ✅ `send` |
| `recv` / `recv_like` (direct neighbor only) | ✅ line 560 | ✅ `mlx_distributed_recv[_like]` | ✅ `recvLike` |
| `all_gather` | ✅ line 502 | ✅ `mlx_distributed_all_gather` | ✅ `allGather` |
| `all_sum` (ring reduce-scatter + all-gather) | ✅ line 483 → `all_reduce`/`all_reduce_impl` 590/665 | ✅ `mlx_distributed_all_sum` | ❌ **not wrapped** |
| `all_max` | ✅ line 488 | ✅ `mlx_distributed_all_max` | ❌ |
| `all_min` | ✅ line 493 | ❌ (no C symbol) | ❌ |
| `sum_scatter` | ❌ **throws** "not supported" (line 584) | n/a | ❌ |
| `all_to_all` | ❌ **does not exist** | ❌ | ❌ |
| `split` | ❌ throws (line 498) | n/a | ❌ |

**Key findings:**

- **`all_sum` already exists** in the forked ring backend (it's a full ring reduce-scatter then all-gather, `all_reduce_impl` at line 665, comment line 694: "first scatter reduce and then gather") and the C symbol `mlx_distributed_all_sum` is already exported. It is simply **not wrapped in Swift** (`MLXDistributed.swift` deliberately omits it — see the file header comment: "Tensor-parallel collectives (all_sum/sum_scatter) are intentionally omitted for now"). All collectives run CPU-stream (`communication_stream` → `Device::cpu`, line 471).
- **`all_to_all` does NOT exist** anywhere — not in `ring.cpp`, not in the C++ public `ops.h` (`grep` shows only `all_sum`, `all_gather`, `send`, `recv`, `recv_like`, `all_max`), not in the C API.

### What TP needs vs what exists

TP needs a per-layer all-reduce(sum). **For 2 nodes we do not need the ring's `all_sum` at all** — an all-reduce over `p=2` is `send(partial) ; recv(peerPartial) ; localAdd`, using the already-wrapped `send`/`recvLike` and the existing sealed channels (§2.4). This is the recommended path: **zero new ring/C++ code, reuses verified crypto.**

If we later want the native `all_sum` (e.g. `p>2`, or to avoid the extra encode/decode copy):
- The C symbol exists; we only add a Swift wrapper:
  ```swift
  public func allSum(_ x: MLXArray, stream: StreamOrDevice = .cpu) throws -> MLXArray {
      try call("all_sum") { res in mlx_distributed_all_sum(&res, x.ctx, group, stream.ctx) }
  }
  ```
  But raw `all_sum` ships **plaintext activations on the wire**, which violates the encrypted-link invariant. So native `all_sum` is only usable if we either (a) fork `all_reduce_impl` to seal/open each segment, or (b) accept plaintext under a separate threat model. Not for v1.

### What EP needs vs what exists

EP needs all-to-all (dispatch + combine). **For 2 nodes, all-to-all = pairwise send/recv** (one peer), so again **no new collective** — implement it as sealed `send`/`recvLike` of the dispatched hidden + expert list, then of the combined partials (§3.2). The ring even handles the 2-node send/recv aliasing (left==right) explicitly (`recv`, ring.cpp ~561).

If we ever need a true N-way all-to-all (>2 nodes): build it on the ring as `p-1` pairwise sends in a fixed schedule (each rank sends its destined chunk to each other rank in rotation), since the ring only allows **direct-neighbor** send/recv — for a non-neighbor you must **relay** around the ring (multi-hop), which for `p>2` is expensive and argues for `jaccl`/mesh instead. Out of scope for 2 nodes.

**Bottom line for the 2-node target: no `ring.cpp` or C-API changes are required.** Everything is built from the existing wrapped `send`/`recvLike` + the existing sealed channels. The only optional Swift addition is an `allSum` wrapper for future `p>2`.

---

## 5. Changes to the Swift codebase

Surgical, additive — keep `ClusterPipeline.swift` intact as the fallback.

### 5.1 New file: `ClusterTensorParallel.swift` (alongside `ClusterPipeline.swift`)

A new decode loop with the **same** public shape as `ClusterPipeline.generate` (so `ClusterServer` / `ClusterContext.makePipeline` can pick either). Differences from the pipeline loop:

- **No head/tail asymmetry.** Both ranks embed (replicated), run every layer, and project to logits + sample. The per-token token `allGather` is kept only as a cheap consistency check (both ranks already sample identically).
- The loop body calls a new shard method `runOwnedLayersTP(_:reduce:)` that, **at each all-reduce point inside each layer**, calls back into a closure provided by the loop. The closure does the sealed `send`+`recvLike`+add (§2.4). This keeps comms in ProviderCore (where the crypto lives) and compute in the fork.
- Sketch (decode step):
  ```swift
  // both ranks; peer = 1 - plan.rank
  var hidden = shard.embed(tokens: inputTokens)         // replicated
  hidden = shard.runOwnedLayersTP(hidden) { partial, site in
      // site e.g. "tp-attn-L17"; ctx binds it into AAD
      let outCtx = ClusterFrameContext(clusterId: plan.clusterId, requestId: requestId,
                                       layerRange: site, seq: nextSeq())
      let sealed = try sealCh!.seal(ActivationCodec.encode(partial.asType(.bfloat16)), context: outCtx)
      let dep = try group.send(toI32(sealed), to: peer); dep.eval()
      let inCtx = ClusterFrameContext(clusterId: plan.clusterId, requestId: requestId,
                                      layerRange: site, seq: peerSeq())
      let cipher = try group.recvLike(MLXArray.zeros([sealedLen(width: 1)], dtype: .int32), from: peer)
      let peerPartial = try ActivationCodec.decode(openCh!.open(toBytes(cipher), context: inCtx))
      return partial + peerPartial            // reduced result, full hidden
  }
  let logits = shard.projectToLogits(hidden)            // replicated lm_head
  let next = Int(argMax(logits, axis: -1).item())
  ```
- **Nonce discipline:** there is now **one `seal`+`open` pair per all-reduce site**, i.e. `2L` per token (TP) and `2L + 2L` (EP). The send channel counter and recv channel counter each advance once per pair, strictly monotonic — same invariant as today, just more frames. AAD `site` strings must be **unique per (layer, reduce-point, request)** and identical on both ranks; `seq` continues monotonically across the whole request. **Critical ordering rule (preserve the deadlock-free discipline):** both ranks must execute the seal/send/recv/open in the **exact same order** every step (mirror the comment at `ClusterPipeline.swift:5-12`). Because both ranks `send` then `recv` to the same peer, and the ring's per-direction sockets are ordered, the schedule must be: every rank `send`s its partial, then every rank `recv`s — never interleave two outstanding reduces.

### 5.2 New file: `ClusterExpertParallel.swift` (gpt-oss only)

Same loop skeleton as 5.1, but the per-layer callback handles both the **attention all-reduce** (identical to TP) and the **MoE dispatch/combine** (§3.2): two sealed send/recv pairs around the locally-owned expert compute. The router runs replicated; the callback receives the local expert outputs + the routing table and exchanges the remote pieces. AAD sites `"ep-attn-L{n}"`, `"ep-dispatch-L{n}"`, `"ep-combine-L{n}"`.

### 5.3 `mlx-swift-lm` fork: shard adapters load **sliced** weights

This is the largest change and lives in the fork (the adapters `GPTOSSShardAdapter.swift` / `LlamaShardAdapter.swift` just bridge to it).

- **New shard variants** loaded with a *TP slice spec* instead of a contiguous `LayerInterval`:
  - Dense (Llama/Mistral): each rank loads **all `L` layers** but only **half the heads** of `q/k/v/o_proj` and **half the rows/cols** of `gate/up/down`. New loader entry, e.g. `LlamaTPShardLoader.loadFromDirectory(dir, rank:, worldSize:)`, slicing weight tensors at load time (column-parallel for qkv/gate/up = row slice; row-parallel for o/down = column slice). KV cache holds only this rank's 16 heads.
  - MoE (gpt-oss): each rank loads **all layers' attention** (TP-sliced as above) but only its **subset of experts** per layer (interleaved placement, §3.4). Router (`gate`) loaded **full** on both ranks.
- **New protocol methods** on `PipelineModelShard` (or a sibling `TensorParallelShard` protocol so the pipeline path is untouched):
  ```swift
  // runs all layers; calls `reduce(partial, site)` at each all-reduce point,
  // expecting the full reduced hidden back.
  func runLayersTP(_ hidden: MLXArray, reduce: (MLXArray, String) throws -> MLXArray) rethrows -> MLXArray
  ```
  For MoE, the same method also calls back for dispatch/combine, OR add a parallel `runLayersEP(_:reduce:dispatch:combine:)`. The fork must expose the per-layer internals (sliced attention, sliced MLP / per-expert MLP) — this is the same kind of "expose a partial forward" change the pipeline path already required (see `PipelineModelShard.swift` header: "Implementing PipelineModelShard … requires a small addition in the mlx-swift-lm fork").
- `embed` and `projectToLogits` become **replicated** (loaded on both ranks) in the TP/EP shards.

### 5.4 `ClusterHeadBringup.swift`: new split strategy

- Add a parallelism-mode selector (env or config): `pipeline` (default, current) vs `tensor` (dense) vs `expert` (MoE, auto-selected when `model_type == gpt_oss` AND mode == tensor/auto).
- When TP/EP: **skip** `LayerPartition.partition` (no contiguous layer split). Instead compute the **head/expert split** by rank (heads split evenly; experts split memory-weighted/interleaved using the same all-gathered budget vector already collected at lines 109-118). Load the TP/EP shard variant (5.3) instead of the contiguous shard.
- The X25519 session agreement (lines 137-155), `ClusterSession`, sealing/opening channels — **unchanged**; TP/EP reuse them verbatim (the directional keys still apply: rank0→rank1 is one key, rank1→rank0 the other). `makeChannels()` / `makePipeline()` gain a `makeTensorParallel()` / `makeExpertParallel()` sibling.
- Gate TP/EP on link type: only enable when the transport is the low-latency local path (TB). Add a guard that refuses TP over a high-RTT link (or warns) — measure RTT at bringup via a few `send`/`recvLike` round trips and fall back to pipeline if RTT > threshold (~5 ms).

### 5.5 `MLXDistributed.swift`: optional `allSum` wrapper

Only needed for the future `p>2` / native-reduce path (§4). **Not required for the 2-node v1.** If added, document that it ships plaintext and is therefore gated behind a non-encrypted threat model.

### 5.6 `ClusterServer.swift`: unchanged control round

The control round (`exchangeRequest`, all_gather of the request descriptor) works identically — every rank still enters `generate` in lockstep. Only swap which loop object `pipeline` points at (pipeline vs TP vs EP). Keep the lockstep `all_gather` control round.

### Summary of edits

| File | Change |
|---|---|
| `Cluster/ClusterTensorParallel.swift` | **new** — dense TP decode loop |
| `Cluster/ClusterExpertParallel.swift` | **new** — MoE EP decode loop |
| `Cluster/ClusterHeadBringup.swift` | mode selector; head/expert split; load TP/EP shard; RTT gate |
| `Cluster/LlamaShardAdapter.swift` / `GPTOSSShardAdapter.swift` | new `load(...rank,worldSize)` TP/EP entry; implement `runLayersTP`/`runLayersEP` bridge |
| `Cluster/PipelineModelShard.swift` | add sibling `TensorParallelShard` protocol (don't touch the pipeline protocol) |
| `Cluster/MLXDistributed.swift` | (optional, future) `allSum` wrapper |
| `mlx-swift-lm` fork | sliced-weight loaders + per-layer reduce callbacks (the real work) |
| `Cluster/ClusterServer.swift` | select loop by mode (minimal) |
| `Cluster/ClusterPipeline.swift` | **unchanged** (fallback) |
| `ring.cpp` / C API | **no change** for 2 nodes |

---

## 6. Phased rollout (2–3 weeks)

### Phase 0 — instrumentation (day 1)
- Reuse the `DARKBLOOM_PROFILE` phase timing already in `ClusterPipeline` (lines 72-149); add the same brackets to the new loops: `seal`, `send`, `recv`, `open`, `reduce_add`, `attn_compute`, `mlp_compute`, `expert_compute`. This is how we'll prove both GPUs are busy and where the `2L` collectives spend time.
- Measure TB-IP RTT with a micro-bench of `send`/`recvLike` round trips.

### Phase A — TP for DENSE models (Mistral), week 1
1. Fork `mlx-swift-lm`: `LlamaTPShardLoader` that slices qkv/o (head split) and gate/up/down (intermediate split); replicate embed + lm_head; per-layer `runLayersTP(reduce:)` callback. Verify single-process `worldSize=1` slice = full model (degenerate reduce = identity).
2. `ClusterTensorParallel.swift`: the loop in §5.1 with sealed send+recv+add as the reduce.
3. `ClusterHeadBringup`: mode `tensor`, head split, RTT gate.
4. **Correctness validation (the gate to ship):** run the SAME greedy prompt (temperature 0) through (a) single-node Mistral, (b) the current pipeline loop, (c) the new TP loop. **Assert token-for-token identical output** for ≥256 generated tokens across several prompts. TP is mathematically exact (same math, partitioned + summed), so any divergence is a bug (slice indexing, missing reduce, dtype). Add this as a `swift test` cluster test (2 in-process ranks if the ring supports loopback, else a 2-machine CI job).
5. **Benchmark:** tok/s on Mistral-24b over TB vs the pipeline baseline; confirm >1.5x and both-GPU utilization from profiling. Use the existing `e2e` benchmark harness pattern (`docs/cluster-benchmark.md`).

### Phase B — EP for MoE (gpt-oss), week 2–3
1. Fork: `GPTOSSEPShardLoader` — TP attention (as Phase A) + per-expert MLP subset (interleaved placement) + replicated router. `runLayersEP(reduce:dispatch:combine:)`.
2. `ClusterExpertParallel.swift`: attention all-reduce + MoE dispatch/combine, all sealed.
3. **Correctness validation:** token-for-token vs single-node gpt-oss greedy, ≥256 tokens, several prompts. EP is also exact (router picks the same experts on both ranks; outputs summed). Validate the routing table is identical on both ranks (assert in a debug build).
4. **Load-imbalance check:** log per-node expert-hit counts per step; confirm interleaved placement keeps it ~balanced; test a skewed prompt.
5. **Benchmark:** tok/s vs pipeline baseline on gpt-oss-20b over TB; target the ~4x headroom called out in the motivation (from ~9–12 to ~30+ tok/s if comms latency cooperates).

### Phase C — hardening (buffer)
- RTT auto-gate + fallback to pipeline on Wi-Fi.
- Batch-dim dispatch for EP (continuous batching alignment).
- Run both Quality-Gate reviewers (codex + claude subagent) per CLAUDE.md on each phase's diff; `swift test` green.

---

## 7. Risks / open questions

1. **CPU-stream collective cost (biggest risk — now MEASURED, confirmed).** All ring send/recv run on the CPU stream (`ring.cpp:471`), and each reduce crosses the GPU↔CPU boundary (the `MLXDistributed.swift` header notes MLX moves the tensor across that boundary at each hop). With `2L` reduces/token (80 for Mistral) we cross that boundary `~4L` times/token vs **once** today. The `comms-bench` harness measured this directly on 2× M4 over Thunderbolt: **83.35 ms/token, 1.04 ms/reduce, ~12 tok/s TP ceiling from comms latency alone** — so naive batch-1 TP is **latency-bound, no better than pipeline**. The two paths that actually help: **(a) TP + batching** (the comms floor is fixed per token-step regardless of batch size, so aggregate throughput scales — the same lever proven for continuous batching at ~2.5× across the 2-Mac cluster); **(b) get the collectives off the CPU stream** — either a GPU-stream transport or **RDMA/`jaccl`** (RDMA-over-Thunderbolt, macOS 26.2+). Note: `jaccl` is **NOT** blocked by the trust policy — the coordinator accepts RDMA-enabled providers (`api/provider.go:1184-1200`); it's simply not yet wired into our ring. JACCL's zero-copy OS-bypass transfer attacks exactly the GPU↔CPU↔socket round-trip that the 1.04 ms/reduce floor comes from, and is the most direct route to making batch-1 TP viable. Secondary mitigations: overlap independent reduces; keep activations bf16.

2. **Encryption overhead, now `2N` collectives/token.** Each reduce = 1 seal + 1 open + 1 `ActivationCodec.encode` + 1 `decode`. ChaChaPoly on 10 KB is ~µs (fine), but `ActivationCodec.encode`/`decode` each **copy the tensor out of / into MLX** (`asData(access:.copy)`, MLXArray construction) — `~4L` extra host copies/token. Profile; if hot, add a fast path that reuses a pinned buffer per reduce site.

3. **Nonce-space growth.** The monotonic 64-bit counter (`ClusterSealingChannel`) now advances `2L`/token instead of 1. At 80/token * say 4096 tokens/request = 327k frames/request — nowhere near `UInt64.max`, and channels are fresh per request (`makeChannels`). **No nonce-exhaustion risk**, but the AAD `layerRange`→`site` strings MUST be unique per reduce point or a frame from layer 17's attn reduce could be replayed into layer 18's; the design pins `seq` monotonic AND `site` per point, so both AAD and nonce differ. Keep both.

4. **Deadlock discipline.** The pipeline loop's correctness rests on "every rank calls the collective in the same order, branching only around it" (`ClusterPipeline.swift:5-12`). TP/EP have `2L`–`4L` collectives/step; a single asymmetric ordering (one rank sends before the other recvs in a way that doesn't pair up) deadlocks the ring. The loop must enforce a rigid schedule: at each reduce point **both ranks `send` then both `recv`**, identical order, no early returns. This is the #1 implementation hazard.

5. **EP load imbalance at batch=1.** Router may send all 4 experts to one node ⇒ the other idles for that layer. Interleaved placement reduces but doesn't eliminate it. The real fix is batched decode (§3.4). Open question: does the 2-node TP/EP path need to integrate with the existing `BatchedEngine` continuous-batching path, or run standalone? Recommend standalone for v1, batched in Phase C.

6. **Does the 24 GB node hold its half of gpt-oss + KV?** gpt-oss-20b q8/MXFP4: experts ~300 MB/expert total (24 layers) → 14 experts ≈ 4.2 GB; attention (8-bit, half the heads) ≈ small; embed+lm_head replicated (8-bit, vocab not given for gpt-oss but ~200k? — **verify `vocab_size` in the gpt-oss config**, it wasn't in the head fields read). KV cache: 24 layers * 8 KV heads (4/rank after TP) * 64 head_dim * 2 (k+v) * 2 bytes * seq_len. At 4096 ctx: `24*4*64*2*2*4096 ≈ 100 MB/rank` — trivial. **mac-24 fits its half comfortably** (≈4–6 GB weights + <1 GB KV ≪ 24 GB). Note `GPU.set(memoryLimit: 0.80*physical)` (`ClusterHeadBringup.swift:97`) ⇒ ~19 GB usable on mac-24 — fine. **Open: confirm gpt-oss `vocab_size` and the replicated lm_head size; if huge, consider sharding lm_head column-parallel + an all-gather before sampling.**

7. **`worldSize=1` / odd splits.** Heads divide by 2 for both models (32→16, 64→32). If a future model has an odd head count or the cluster grows to 3 nodes, the even-split assumption breaks — need padding or per-rank uneven head counts, and `p>2` needs real `all_sum`/all-to-all (§4 Option B). The 2-node design must assert `worldSize==2` and even divisibility at bringup and fall back to pipeline otherwise.

8. **Wi-Fi fallback correctness.** The RTT gate must be reliable; a TP run that silently starts over Wi-Fi will be ~0.3 tok/s. Make the gate fail loud (log + fall back to pipeline), and surface the chosen mode in provider telemetry.
