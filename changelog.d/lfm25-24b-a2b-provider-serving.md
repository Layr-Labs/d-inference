### LFM2.5-24B-A2B provider serving

- Advertise and serve exactly `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` and its catalog id `lfm2.5-24b-a2b` through the native CBv2 `LFM2MoEModel` adapter; other `lfm2_moe` checkpoints stay unadvertised.
- Select native paged attention KV and SSD complete recurrent checkpoints (attention KV plus short-conv state) by default for those ids, with the existing kill switches; MTP stays off because no assistant exists.
- Charge KV for the 10 attention layers only (the pre-load estimate previously counted the 30 conv layers as attention), and conv state as fixed per-request engine state.
- Apply the artifact's sampling defaults (`temperature 0.1`, `top_k 50`, `repetition_penalty 1.05`) to fields a request omits.
