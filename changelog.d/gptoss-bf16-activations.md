### GPT-OSS bf16 activations and KV

- A bf16 GPT-OSS checkpoint such as `gpt-oss-20b` now keeps bf16 activations
  and native K/V on every layer. The expert SwiGLU clamp used float32 bounds,
  which promoted every layer after the first to float32; its scalar bounds now
  take the activation dtype. Float32 models are unchanged.
- `gpt-oss-20b` native full-attention K/V falls from 49,152 to 24,576 bytes per
  token. A slot grant holds about twice as many GPT-OSS tokens, and the
  heartbeat `kv_bytes_per_token` halves. Admission, paged storage and
  checkpoint identity already use the observed native K/V types.
- Measured cold TTFT falls 21-26% on an M5 Ultra (512-8,192-token prompts)
  and 14-18% on an M3 Ultra (2,048-32,768 tokens). Aggregate decode at batch 8
  rises from 153 to 519 tokens/s on the M5 Ultra and from 275 to 314 on the
  M3 Ultra.
- Output is not bit-identical to the float32 path. On 6 teacher-forced samples
  of 256 tokens, mean token NLL moved from 3.8146 to 3.8123 and top-1
  agreement with the float32 path was 93.3%.
- GPT-OSS SSD complete checkpoints written with float32 layer types use a
  different checkpoint namespace and are not restored. Matching prompts
  prefill cold until new checkpoints are written; the old files expire.
- The 3.5 GiB `gpt-oss-20b` activation floor is unchanged. It was measured on
  the float32 path.
