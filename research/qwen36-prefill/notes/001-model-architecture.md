# 001 — Qwen 3.6 35B A3B snapshot architecture

Status: kept (facts)

Path: `/Users/benchmark/.cache/huggingface/hub/models--qwen3.6-35b-a3b-vl-mtp-mxfp8/snapshots/local`

| Field | Value |
|---|---|
| `model_type` | `qwen3_5_moe` |
| Disk | 20 GiB / index `total_size` 21,281,612,512 |
| Quant | 4-bit affine, group 64; every `mlp.gate` and `shared_expert_gate` is 8-bit |
| `hidden_size` | 2048 |
| `num_hidden_layers` | 40 |
| `num_experts` | 256 |
| `num_experts_per_tok` | 8 |
| `moe_intermediate_size` | 512 |
| `shared_expert_intermediate_size` | 512 |
| `num_attention_heads` | 16 |
| `num_key_value_heads` | 2 |
| `head_dim` | 256 |
| `full_attention_interval` | 4 |
| GDN | 16 k-heads / 32 v-heads / 128 dim / conv 4 |
| `vocab_size` | 248320 |
| `max_position_embeddings` | 262144 |
| MTP | inline, `block_size=3`, shares embeddings + lm_head |
| Vision | Qwen3.5 tower, `out_hidden=2048`, 27 deep, present but out of scope |

Layer schedule (confirmed): 30× `linear_attention` (GDN) + 10×
`full_attention` at layers 3,7,11,15,19,23,27,31,35,39.

Tensors: 2120. Prefixes: `language_model` 1757, `vision_tower` 333, `mtp` 30.

Implication: prefill cost is **MoE weight traffic + 30 GDN scans + 10
quadratic attns + a 248k lm_head**. Active params per token are ~3B
by marketing; at prefill chunk scale the router touches ~all 256
experts, so the *chunk* pays for nearly the whole 35B.
