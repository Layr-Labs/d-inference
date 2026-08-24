# MINDMAP — Qwen 3.6 35B-A3B prefill

Linked idea graph. Every node has a note or a report. Status:
`open` | `active` | `kept` | `dead` | `roofed` | `needs-measure`.

```mermaid
flowchart TB
  GOAL["GOAL: 2.5x aggregate CBv2 prefill"]

  GOAL --> PHYS[Physics]
  GOAL --> SCHED[Scheduler / CBv2]
  GOAL --> MOE[MoE / experts]
  GOAL --> ATTN[Attention / GDN]
  GOAL --> BYTES[Extra traffic]
  GOAL --> HW[Metal / M3 Max]
  GOAL --> CORR[Correctness + merge]

  PHYS --> P1[Prefill reads weights per chunk not per token]
  PHYS --> P2[E=256 almost fully touched at 512+ tokens]
  PHYS --> P3[4-bit packed vs bf16 dequant roof]
  PHYS --> P4["B=4 unpacked ~ 1x aggregate"]

  SCHED --> S1[Solo stripe 2048]
  SCHED --> S2[Packed prefill capability vs actual fire]
  SCHED --> S3[Chunk 512 vs 2048 vs one-shot]
  SCHED --> S4[Mean-TTFT cap - policy not throughput]
  SCHED --> S5[Prefix cache off]

  MOE --> M1[Expert-tile E=256 trust]
  MOE --> M2[Fused gate_up - shipped]
  MOE --> M3[Direct expert reduction - rolled back 0.8.9]
  MOE --> M4[Mega-kernel - dead 63-71 percent slower]
  MOE --> M5[Router fusion - dead wash]

  ATTN --> A1[10 full-attn L-squared]
  ATTN --> A2[30 GDN serial scan]
  ATTN --> A3[D=256 Steel - correct unmeasured]
  ATTN --> A4[GDN 4-in-1 proj - rolled back 0.8.9]
  ATTN --> A5[Sparse 32K+]

  BYTES --> B1[LM-head narrowing]
  BYTES --> B2[Last-query tail]
  BYTES --> B3[Mask+softmax QK epilogue]
  BYTES --> B4[Logits transient stripe amplification]

  HW --> H1[Zero kernel overlap 24 percent peak]
  HW --> H2[maxBufferLength 80.6 GiB]
  HW --> H3[Power posture LPM 2x lie]
  HW --> H4[164 GiB fatal on this Mac]

  CORR --> C1[Greedy temp0 match]
  CORR --> C2[KV / GDN / MoE routing]
  CORR --> C3[No decode regression]
  CORR --> C4[Tests + reviewer]
```

## Edges that matter (do not lose these)

- `P4 → S2`: the 4x-requests=1x-throughput fact **is** the packed-prefill
  business case. If S2 already fires, P4 must be re-measured; the 2026-08-19
  number may be stale relative to 0.8.6 claims.
- `P3 → GOAL`: if weights dequant to bf16, B=1 2.5x is **roofed**. Move
  the 2.5x onto aggregate B=2/B=4.
- `S1 + M1`: stripe only pays after trust removes expert-descriptor
  drains. Stripe alone is a wash. LPM stripe is a regression.
- `M3 + A4 → C3`: v0.8.8 taught us prefill wins that punch decode are
  not keeps. Reviewer veto.
- `H1`: concurrent encode is a structural 2x **if** MLX can submit
  independent kernels. Needs a real overlap counter, not hope.
- `H2 + H4`: any shape that asks Metal for >80 GiB dies. Vision and
  huge logit tensors are in this blast radius.
- `S4`: FCFS / max concurrent partial prefills halves **mean TTFT** at
  constant aggregate. Do not confuse that with the 2.5x metric.
- `A1`: L² only dominates long full-attn layers. At 8K, 10 layers of
  8K² may or may not beat MoE weight traffic. Measure, don't assume.

## Ranked bets (2026-08-24, pre-baseline)

| Rank | Node | Expected | Risk | Why now |
|---:|---|---|---|---|
| 1 | S2 packed actually on | 1.5–4x agg B=4 if off | Low if already on | First measure H0 |
| 2 | S3 fewer weight re-reads | 1.1–1.4x B=1 | Memory, LPM | Physics of P1/P3 |
| 3 | H1 wavefront | up to ~2x if 24% peak is real | High / MLX | Structural |
| 4 | B1/B2 residual narrowing | ~10-14% B=1 | Low | Already partly shipped |
| 5 | A2 GDN parallel scan | 5-7% | Numeric tolerance | After bigger fish |
| 6 | A4/M3 re-enable with decode guard | 6-10% B=1 | High (0.8.8) | Only with decode A/B |
| 7 | A5 sparse | 8K: none; 32K+: large | Quality | Out of 8K scope |
| 99 | M4 mega-kernel | negative | Proven | Dead |

Update this table after the baseline lands.
