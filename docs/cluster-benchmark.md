# Cluster Inference Benchmark — Wi-Fi vs Thunderbolt

Measured throughput for Darkbloom's pipeline-parallel cluster mode running a
single model sharded across two Apple Silicon Macs, comparing the inter-node
ring transport over Wi-Fi vs a direct Thunderbolt link.

> **Scope.** These are batch=1, greedy-decode numbers — the per-token latency a
> single user sees. They are *not* aggregate-throughput numbers (batching is the
> separate, larger lever — see [What this does *not* measure](#what-this-does-not-measure)).

## Results

| Model | Wi-Fi | Thunderbolt | TB speedup |
|---------------------|-----------|------------|------------|
| Mistral-24B (dense) | 3.7 tok/s | 4.6 tok/s  | **+24%**   |
| GPT-OSS-20B (MoE)   | 9.0 tok/s | 12.3 tok/s | **+37%**   |

*Decode throughput, batch=1, greedy. Warm steady-state (first run discarded),
96–128 token generations, identical prompt per model. Compute-controlled via
per-phase profiling — the GPU-compute phase (`owned_layers`) was confirmed equal
across transports, so the delta is attributable to the ring transport.*

### ⚠️ Single-node baseline — pipeline parallelism is *slower* for a model that fits

GPT-OSS-20B-q8 fits comfortably on one 32 GB Mac. Running it single-node
(`solo-bench`, same prompt, same M4 head) gives **~30 tok/s** — far above either
clustered number:

| GPT-OSS-20B configuration | Decode tok/s | vs single-node |
|----------------------------|-----------|----------------|
| **Single node (mac-32 alone)** | **~30.0** | baseline |
| Cluster, Thunderbolt           | 12.3      | **2.4× slower** |
| Cluster, Wi-Fi                 | 9.0       | **3.3× slower** |

This is the headline finding, and it is *expected*: at batch=1, pipeline
parallelism runs the two GPUs **sequentially** (one idle while the other
computes) and adds a network hop + pipeline bubble on top. Total compute is
unchanged, so splitting a model that already fits is pure overhead — you add a
machine and get *negative* return.

**Pipeline parallelism only earns its keep on models too big to fit on one node**
(e.g. Mistral-24B bf16 ~48 GB, Llama-70B ~40 GB), where the single-node
alternative is "won't load." For co-located machines and models that fit, the
right strategy is **tensor / expert parallelism** (both GPUs compute every
token), which can *beat* single-node — pipeline structurally cannot. See
[cluster-tensor-expert-parallel.md](architecture/cluster-tensor-expert-parallel.md).

## Hardware Setup

| Node     | Role          | Machine  | Chip         | RAM   |
|----------|---------------|----------|--------------|-------|
| `mac-32` | head (rank 0) | Mac16,12 | Apple M4     | 32 GB |
| `mac-24` | tail (rank 1) | Mac16,8  | Apple M4 Pro | 24 GB |

- **Total cluster memory:** 56 GB unified
- **Ring (inter-node activation link):**
  - Wi-Fi — `192.168.1.x`, ~42 ms RTT
  - Thunderbolt — direct link-local `169.254.x` (mac-32 `en3` ↔ mac-24 `en9`), ~1 ms RTT
- **Coordinator link:** Wi-Fi in both cases. The coordinator carries only control
  messages and encrypted response chunks — *no per-token activations* — so it is
  deliberately left on Wi-Fi and does not affect the ring benchmark.
- **Activation encryption:** every hidden-state hop crosses the wire as
  X25519 + ChaCha20-Poly1305 AEAD ciphertext over TCP, on both transports.

## Memory-Weighted Layer Split

Layers are partitioned proportionally to each node's available budget
(`RAM − 10 GB` reserved per node), so the 32 GB head carries the larger share.
Weight ratio **22 : 14** (head : tail).

| Model              | Total layers | head (`mac-32`, 32 GB) | tail (`mac-24`, 24 GB) |
|--------------------|:------------:|:----------------------:|:----------------------:|
| Mistral-24B-8bit (dense) | 40     | 24 layers              | 16 layers              |
| GPT-OSS-20B-q8 (MoE)     | 24     | 15 layers              | 9 layers               |

## Why Thunderbolt helps MoE more than dense

Note (refined by the per-op trace below): the per-token wait the transport affects
is **round-trip latency on the blocked recv/allgather steps**, not raw data
transfer — the trace shows the actual hop is ~0.03 ms of transfer. Higher-latency
Wi-Fi inflates how long each rank sits blocked waiting for the round-trip to
*complete*; Thunderbolt's lower latency shrinks that wait. That latency cost is
roughly **fixed per token** regardless of model. A Mixture-of-Experts model does
**less compute per token** (only top-k experts fire), so the fixed wait is a
*larger fraction* of its shorter token, which is why moving from Wi-Fi to TB helped
MoE more (+37%) than the dense model (+24%).

**Takeaway:** as inference gets more compute-efficient (MoE, smaller or
more-quantized models), the per-token wait — and thus interconnect latency —
matters *more*, not less.

## Per-Token Trace (the bottleneck, fully decomposed)

Full per-operation tracing (`DARKBLOOM_TRACE=1`), steady-state decode, **llama-8b**,
2-rank pipeline. Every primitive is force-eval'd before its timer closes, so each
number is that op's real cost (MLX laziness can't smear compute into a later
barrier). Both ranks traced; the per-token critical path is reconstructed by
reading head + tail together.

### Single-GPU baseline (no cluster, whole model, `solo-bench`)

| Machine | tok/s | ms/token | notes |
|---------|-------|----------|-------|
| M4 Pro (mac-24) | ~48 | **20.8** | whole model, GPU saturated, **no bubble** |
| base M4 (mac-32) | ~22 | **44.8** | whole model |

**Why the M4 Pro is ~2× the base M4 (it's memory bandwidth, not cores).** Decode
is memory-bandwidth-bound — each token streams the active weight set from memory —
so decode tok/s tracks bandwidth, not GPU-core count:

| | GPU cores | mem bandwidth | bus | measured llama-8b |
|---|---|---|---|---|
| base M4 (mac-32) | 10 | ~120 GB/s | 128-bit | 22 tok/s |
| M4 Pro (mac-24) | 16 | ~273 GB/s | 256-bit | 48 tok/s |

The **measured** speed ratio (48/22 = **2.18×**) matches the **bandwidth** ratio
(273/120 = **2.28×**) almost exactly — and is far above the GPU-core ratio (1.6×).
That's the direct proof decode is bandwidth-bound: the win tracks the wider memory
bus (the M4 Pro is a wider die: 256-bit vs 128-bit, double the LPDDR channels),
not the extra cores (those help prefill, which is compute-bound). Consequence for
the cluster: our memory-weighted split loads **more layers onto the 32 GB base M4**
(for KV-cache headroom), i.e. onto the *bandwidth-poorer* chip — good for fitting,
bad for latency. See the bandwidth-weighted-split item in the perf backlog.

### Localhost 2-rank trace (both ranks on M4 Pro, one GPU) — freshly verified

A contrived config (two `cluster-provider` processes sharing one M4 Pro GPU over
a 127.0.0.1 ring) used to isolate the *non-network* costs cleanly. **29.3 ms/token.**
Per-step averages over 63 decode steps, with what executes each:

| Step (execution order) | Process | ms | Type |
|------------------------|---------|----|------|
| embed | head | 0.20 | GPU |
| layers_compute (head's 16 layers) | head | 11.11 | GPU |
| codec_encode + aead_seal + to_i32 | head | 0.21 | CPU |
| send_hop | head | 0.09 | network (loopback) |
| recv_wait (blocked on head) | tail | 11.84 | idle (overlaps head GPU) |
| to_bytes + aead_open + codec_decode | tail | 0.05 | CPU |
| layers_compute (tail's 16 layers) | tail | 14.91 | GPU |
| logits_compute (norm+lm_head+argMax) | tail | 2.31 | GPU |
| allgather (token back to head) | head/tail | 17.49 / 0.16 | network + idle |
| readback | both | 0.01 | CPU |

Critical path (the steps that serialize into the token): embed 0.2 + head layers
11.1 + (CPU+send 0.3) + tail layers 14.9 + logits 2.3 + token-gather 0.2 ≈ **29 ms**.
`recv_wait` (tail) and the head's 17 ms `allgather` are **idle waiting**, not work —
each rank blocked on the other; they overlap the other rank's GPU compute and do
**not** add to the total. **GPU ≈ 28.5 ms (97%), CPU ≈ 0.3 ms (1%), network ≈ 0.3 ms (1%).**

### Cross-Mac cluster (head = base M4, tail = M4 Pro, over Thunderbolt) — verified

**44.2 ms/token (~22.6 tok/s).** Per-step averages over 63 decode steps, labeled
logs, re-confirmed (matches an earlier run's 43.6 ms within noise):

| Rank | Phase | ms | % of step | Type |
|------|-------|----|-----------|------|
| HEAD (base M4) | `layers_compute` | 28.03 | 63% | GPU (head's 16 layers) |
| HEAD | `allgather` | 15.22 | 34% | **idle** — waiting for tail's token |
| HEAD | embed + codec_encode + aead_seal + to_i32 + send_hop | ~0.94 | 2% | CPU + network |
| TAIL (M4 Pro) | `recv_wait` | 30.52 | 69% | **idle** — waiting for head's activation |
| TAIL | `layers_compute` | 11.35 | 26% | GPU (tail's 16 layers) |
| TAIL | `logits_compute` | 2.28 | 5% | GPU (norm+lm_head+argMax) |
| TAIL | aead_open + to_bytes + codec_decode + allgather | ~0.12 | 0.3% | CPU |

`send_hop` (the actual Thunderbolt transfer) = **0.02 ms**.

### Second model — GPT-OSS-20B (MoE), same cross-Mac rig — verified

**37.3 ms/token (~26.8 tok/s)** — faster than llama-8b (44.2) because MoE fires
only the top-4 of 32 experts → less GPU compute per token. Same structure, shifted
proportions:

| Rank | Phase | ms | % | Type |
|------|-------|----|---|------|
| HEAD (base M4) | `layers_compute` | 24.14 | 65% | GPU |
| HEAD | `allgather` | 11.71 | 31% | **idle** |
| HEAD | embed + codec + seal + send | ~1.4 | 4% | CPU+net |
| TAIL (M4 Pro) | `recv_wait` | 26.88 | 72% | **idle** |
| TAIL | `layers_compute` | 6.68 | 18% | GPU (MoE — lighter) |
| TAIL | `logits_compute` | 3.66 | 10% | GPU (201k vocab — heavier than llama's 128k) |
| TAIL | crypto+codec+allgather | ~0.10 | 0.3% | CPU |

`send_hop` = **0.03 ms** (same as llama — network is ~nothing regardless of model).

**Cross-model correlation (the point):** the structural findings hold on both — bubble
dominates (GPU ~92–94%), crypto/network negligible (~0.1%), cluster ≈ slowest node.
The proportions shift exactly as predicted: MoE's lighter compute makes the *fixed*
~0.3 ms overhead a slightly larger fraction (8% vs 6%) — the same mechanism behind
"Thunderbolt helped MoE more" above. GPT-OSS's bigger vocab also shows up as a
heavier `logits_compute` (3.7 vs 2.3 ms). The trace explains both.

### What the trace proves (measured, not inferred)

1. **The bottleneck is the pipeline bubble — ~95% of the token is sequential GPU
   compute that never overlaps.** Head computes 28.0 ms (tail idle, shown as its
   30.5 ms `recv_wait`); then tail computes 11.4 + 2.3 ms (head idle, shown as its
   15.2 ms `allgather`). Critical path ≈ 28.0 + 11.4 + 2.3 + ~1 ≈ 44.2 ms.
2. **Overhead is provably negligible.** Crypto (aead_seal + aead_open) = **0.04 ms**;
   serialization (to_bytes/to_i32/codec) ≈ **0.3 ms**; the actual Thunderbolt hop
   (`send_hop`) = **0.03 ms**. Total ~1 ms (≈2%). Crypto, serialization, and the
   network are *not* the cost.
3. **The network is ~0.1% of a token.** `send_hop` is 0.03 ms even over real
   Thunderbolt — confirming a faster transport (incl. RDMA) would do ~nothing for
   the pipeline path. (Contrast tensor parallelism, which is the opposite: ~all
   comms — see the TP comms-floor section.)
4. **Cluster ≈ slowest GPU alone.** Cross-Mac 44.2 ms ≈ base-M4-alone 44.8 ms, and
   **2× slower** than M4-Pro-alone (20.8 ms). The split bought nothing for latency:
   the work is serial (bubble) and the slow base-M4 head dominates the critical
   path (28 of 44.2 ms). A single GPU has no bubble — it streams the whole model as
   one saturated, uninterrupted graph.

(An earlier coarse profile reported a single `recv_hop` ~25–75 ms lumping
idle-wait + transit; the fine-grained trace above separates them and confirms the
transit slice is ~0.03 ms — the wait is the bubble.)

## What this does *not* measure

- **Single-node baseline.** At batch=1, pipeline parallelism runs the two GPUs
  *sequentially* — total compute is unchanged, and clustering adds the network hop
  + pipeline bubble on top. So for a model that fits on one node, single-node is
  *faster* than clustered. Clustering's value is fitting models that do **not**
  fit on one node (e.g. Mistral-24B bf16 ~48 GB, Llama-70B ~40 GB), where the
  single-node alternative is "won't load." Thunderbolt clustering nearly recovers
  single-node speed while unlocking those larger models.
- **Batched throughput.** These are single-stream latencies. The larger speed
  lever is **batching / continuous batching** — serving multiple requests so both
  GPUs stay busy and the pipeline bubble fills, approaching ~2× aggregate
  throughput. That is orthogonal to the transport comparison here.

## Continuous batching — the throughput win (validated)

Path A (continuous batching) is implemented and validated on a real 2-rank ring
(`[cluster].batched = true`). Concurrent requests are admitted into one batched
`[B, hidden]` forward pass; decode is bandwidth-bound, so B requests cost ~one
request's per-step weight streaming.

Two configurations measured (llama-8b, 4 requests × 64 tokens):

| Setup | Serial tok/s | Batched B=4 tok/s | Speedup |
|-------|-------------|-------------------|---------|
| Single machine, 2-rank localhost ring (M4 Pro) | 26.8 | 50.2 | ~1.9× |
| **Two Macs (mac-32 + mac-24) over Thunderbolt** | **13.6** | **34.1** | **~2.5×** |

**Validated end-to-end across two physical Macs over Thunderbolt.** Continuous
batching ran with the head on mac-32 (M4, 32 GB) and the peer on mac-24
(M4 Pro, 24 GB), activations crossing the real TB link. Multiple full
drain-and-readmit cycles held (3 rounds × 3 concurrent + 4-way batches, each
returning distinct correct text, both nodes stable). The cross-Mac *relative*
win is larger (~2.5×) because each request pays the real inter-node hop per
token, which batching amortizes across the batch.

Two bugs were found and fixed on hardware: an AEAD nonce desync between the
admit and decode rounds, and an empty-batch filter crash on full drain. See
`ClusterBatchScheduler` / `ClusterBatchServer` / `ClusterBatchControl`.

> Cross-Mac run used localhost SSH tunnels over the Thunderbolt link (`-L`/`-R`
> forwards, all ring + coordinator endpoints on 127.0.0.1). This carries the
> traffic across the real TB wire while keeping every connection loopback-local,
> which also sidesteps macOS Local Network Privacy blocking the ad-hoc-signed
> binary's direct cross-machine connects. A stably code-signed binary would
> allow direct (untunneled) cross-machine ring connections.

## Where the slowdown comes from — loop overhead vs distribution

To separate "the cluster decode loop is unoptimized" from "distribution is
fundamentally costly," we ran the cluster's exact loop discipline (manual
`argMax`, `evalEvery: 4`, the per-step `.eval()` barriers) on a **single
machine with no network** (`loop-diag`), against MLX's native `generate`
(`solo-bench`). GPT-OSS-20B on the M4 Pro:

| Path | Decode tok/s | What it isolates |
|------|-----------|------------------|
| `solo-bench` (MLX native generate) | ~57 | single-node ceiling |
| `loop-diag` (cluster loop, 1 node, **no network**) | ~51 | **loop overhead only** |
| Cluster, Thunderbolt (2 nodes) | 12.3 | loop + network + pipeline bubble |
| Cluster, Wi-Fi (2 nodes) | 9.0 | loop + worse bubble |

**The cluster loop costs only ~10% (57 → 51).** The remaining ~4× (51 → 12) is
*distribution* — the network hop and the sequential-GPU pipeline bubble — not
code quality. **Making the cluster loop byte-identical to single-node cannot
close the gap; the degradation is structural to pipeline parallelism.**

## Can tensor parallelism fix it? — the comms-floor measurement

Pipeline runs the two GPUs sequentially. Tensor parallelism (TP) instead has
*both* GPUs compute every token in parallel, exchanging partials via an
all-reduce after attention-out and after the MLP down-projection — ~`2 × layers`
all-reduces per token. The question is whether that comms cost is small enough
for TP to approach (or beat) single-node.

`comms-bench` measures it directly: it joins the same ring and times
`2 × layers` all-reduce-sized collectives per token. Mistral dimensions
(hidden=5120, 40 layers → 80 reduces/token), 2× M4 over **Thunderbolt**:

```
83.35 ms/token comms floor · 1.042 ms/reduce · 80 reduces · TP ceiling ≈ 12 tok/s
```

**Finding: naive TP at batch=1 is latency-bound at ~12 tok/s — no better than
pipeline, ~4× below single-node.** Each all-reduce costs ~1 ms (mostly latency:
the CPU-stream GPU↔CPU crossing + `.eval()` barrier, not the ~20 KB payload),
and the 80 reduces are strictly sequential (layer N+1 can't start before layer
N's reduce returns). Faster GPUs cannot help — the token is bound on the wire.

**The two paths that *do* help (and should gate the TP roadmap):**

1. **TP + batching.** The ~83 ms comms floor is *fixed per token-step regardless
   of batch size* (payload barely grows). At batch=B you pay it once but produce
   B tokens of parallel compute, so aggregate throughput scales while the comms
   floor stays flat. TP's win is **throughput, not single-stream latency** — the
   same reason datacenters run TP with batching, never TP at batch=1.
2. **GPU-stream collectives.** The 1.04 ms/reduce is inflated by the ring
   running collectives on the **CPU stream** (every reduce crosses
   GPU→CPU→socket→CPU→GPU). Moving them to the GPU stream could cut this to
   ~0.2–0.3 ms, lifting the batch-1 TP ceiling from ~12 to ~40+ tok/s. This is
   the #1 risk flagged in
   [cluster-tensor-expert-parallel.md](architecture/cluster-tensor-expert-parallel.md).

## Reproducing

1. Set the ring transport in `~/.config/darkbloom/provider.toml` on **both** nodes
   by pointing the `[[cluster.members]]` `address` fields at either the Wi-Fi IPs
   (`192.168.1.x`) or the Thunderbolt link-local IPs (`169.254.x`).
2. Start the tail: `cluster-provider <model-dir> --peer`
3. Start the head (rank 0): `cluster-provider <model-dir>` (reads the coordinator
   URL from `[coordinator]` in the config).
4. Optional profiling: prefix either node with `DARKBLOOM_PROFILE=1` for the
   per-phase breakdown, and `MLX_RING_VERBOSE=1` for ring join diagnostics.
5. Send an OpenAI-compatible request to the coordinator's
   `POST /v1/chat/completions`. Discard the first (cold) run; average the next few.

Benchmark harnesses (all under `provider-swift`, build with
`swift build -c release --product <name>`):

- `solo-bench <model-dir> [maxTokens] [iterations]` — single-node, MLX native generate.
- `loop-diag <model-dir> [maxTokens] [iterations]` — single-node, cluster loop discipline (isolates loop overhead).
- `batch-bench <model-dir> [batchSize] [maxTokens] [iterations]` — batched throughput via BatchScheduler.
- `comms-bench [hiddenSize] [layers] [tokens]` — TP comms floor; run on **both** nodes (joins the ring).

> **macOS note.** The cluster head must run in a GUI Terminal session (or be
> granted **Local Network** access in System Settings → Privacy & Security).
> macOS Local Network Privacy silently blocks LAN/link-local connections from
> binaries launched over SSH, which manifests as the ring failing to join with
> `errno 65 (EHOSTUNREACH)` despite the peer being reachable.
