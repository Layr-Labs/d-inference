### Nemotron 3.5 Lightning decodes faster without its speculative head

- Under the default `mtp_mode = "auto"` Lightning now serves plain decode instead of its embedded MTP head. Plain decode steps commit a Metal command buffer every 100 operations instead of after almost every MoE layer, which outruns the head's speculative rounds with the same outputs at temperature 0, and the provider holds about 7 GB less. Explicit `mtp_mode = "on"` keeps the head.
- Cache identity includes the MTP configuration, so a provider's existing Lightning checkpoints stop matching and age out within their 30-minute lifetime.
