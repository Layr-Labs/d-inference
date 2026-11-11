### LFM2.5 measured activation floor

- `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` and `lfm2.5-24b-a2b` now reserve a measured 2.0 GiB activation floor instead of the 5.5 GiB default. The worst measured non-KV peak was 1.28 GiB, at batch 1 with a 131,000-token prompt.
- A provider serving only this model needs about 18.2 GB free to cold-load it, down from 21.7 GB. The default-config 36 GB Macs that the old reserve refused can now load it when that much memory is free. Its KV budget grows by 3.5 GiB.
- Serving sets with any other model keep the larger floor; `DARKBLOOM_ACTIVATION_RESERVE_GB` can still only raise it. The coordinator's servability mirror moves with this change.
