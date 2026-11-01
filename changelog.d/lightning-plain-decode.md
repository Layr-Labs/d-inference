### Nemotron 3.5 Lightning decodes faster without its speculative head

- Under the default `mtp_mode = "auto"` Lightning now serves plain decode instead of its embedded MTP head. Plain decode steps commit a Metal command buffer every 100 operations instead of after almost every MoE layer, which outruns the head's speculative rounds with the same outputs at temperature 0 on most text, and the provider's peak footprint falls by about 2 GB. Explicit `mtp_mode = "on"` keeps the head.
- Its complete checkpoints keep native rows by default, as they did beside the head, so a cache hit's output does not move. A global `balanced` in a saved `provider.toml` does not change that; `k4v4`, a per-model setting or the process switch do. Lightning's target-only artifact and explicit `mtp_mode = "off"` follow the same default.
- Cache identity includes the MTP configuration, so a provider's existing Lightning checkpoints stop matching and age out within their 30-minute lifetime.
