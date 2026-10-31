### Two-Mac clusters follow the provider's KV quantization

- A pair's stage KV now uses the same live precision a single Mac uses for the
  model: `engine_v2_kv_quantization` (global or per model) and
  `DARKBLOOM_CBV2_KV_QUANTIZATION`, resolved on each Mac and passed to its
  worker. The default stays native; pairs whose Macs keep it are unchanged.
- With `balanced`, `k8v4` or `k8v8`, the Qwen 3.5 family (Bonsai included),
  Gemma 4 and Nemotron 3.5 stages and every Qwen tensor-parallel row's
  request-owned lanes (9B, 27B, Qwen3.5/3.6 35B A3B, any capacity) store packed KV on the provider's own pool, after the same kernel check,
  and their memory planning counts packed rows. Both Macs must resolve the same
  precision; otherwise their load agreements differ and the pair refuses to
  load. Set the pair's model to `native` per model to keep a packed global
  setting off the pair.
- Packed stages keep no prompt prefixes, as on one Mac for packed KV. Phase
  split, GPT-OSS and GLM refuse a packed precision; MiMo stays native. The pair's SSD prefix records stay exact native states.
- `DARKBLOOM_CLUSTER_KV_BACKEND=contiguous` is removed: cluster stage KV is
  paged only.
