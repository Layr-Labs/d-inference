### Bonsai FP32 residual stream and the cluster memory gate under pressure

- Bonsai (Prism) packs keep their FP32 residual stream on the fused Qwen 3.5 decode, verify and stage paths. The fused residual step rounded each FP32 branch to the stream's FP16 embedding dtype, so the stream stayed FP16 and a Bonsai producer stage's residual left its FP32 contract; such a stream now takes the unfused sum, as the unfused forward computes it. Qwen 27B and the other uniform-dtype rows are unchanged.
- The cluster load gate's room-making pass runs only at normal memory pressure. Above it the gate withdraws all file cache on purpose, and a refusal now stands on the gate's own sample instead of a fresh one taken after the pass.
