### Wider mixed-step prefill for Gemma 4

- Gemma 4 prefills prompts in 2,048-token chunks with a 4,096-token step budget, including while other requests are decoding, instead of 512-token chunks beside decode. Busy engines reach the first token sooner and decode each stream faster; solo prefill, KV capacity, paged ring sizes, load quotations and activation floors are unchanged.
- Gemma 4 image and video requests keep 512-token chunks, so their attention memory is unchanged.
- A decode token that shares a step with a long prompt now waits for a 2,048-token chunk instead of a 512-token one: typical inter-token gaps shrink, the slowest grow.
- GPT-OSS and dense Qwen3.5/3.8 also reached the first token sooner with the wide geometry, but at eight 32k-token prompts it raised their activation peaks further above their memory floors, so they keep the 512-token chunk and 2,048-token step by default. Nemotron 3.5, Bonsai, MoE Qwen, Qwen3-VL, Qwen4, MiMo and other families keep them too.
- Set `DARKBLOOM_CBV2_PREFILL_CHUNK=512` and `DARKBLOOM_CBV2_STEP_TOKENS=2048` to restore the previous Gemma 4 geometry, or `2048` and `4096` to opt another family in; `darkbloom start` forwards both to the background provider. Either override disqualifies reviewed serving and deadline profiles, like other `DARKBLOOM_CBV2_*` settings.
