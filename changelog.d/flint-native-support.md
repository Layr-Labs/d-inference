### Native Flint support

- Add native Recursive Flint loading and CBv2 serving for the official group-64 affine INT4 artifact with INT8 embeddings and native BF16 KV. Live KV and checkpoint precision must both be native.
- Enforce the loaded artifact context limit for prompt plus reserved output before request admission.
- Preserve automatic reasoning, separate reasoning output, validate complete schema-aware tool frames and retain nulls in tool history. Explicit thinking/effort controls, media, combined JSON response-format/tools and unrepresentable raw `</arg_value>` history return errors.
- Omit unused prefill vocabulary projections while preserving the full trunk and every KV write. Dense/expert NAX execution is captured; a speedup and the prefill/decode targets remain unproven.
- Credit Prince Canuma's MIT mlx-vlm implementation and Recursive's Apache-2.0 rec reference in the SDK notices. Physical qualification remains scoped to the accompanying evidence; MTP, reduced KV, model publication and provider release are outside this change.
