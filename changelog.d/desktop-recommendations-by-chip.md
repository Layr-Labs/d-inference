### Recommended models from Macs with the same chip

The desktop app's "Recommended for your Mac" now ranks models by what Macs with
the same chip earned per day from each model over the last 24 hours (the typical
Mac first, then the average), when the coordinator publishes those figures in
`/v1/stats` `model_earnings[].by_chip`. Network-wide 7-day totals favor models
that many fast Macs serve, which can pay a slower Mac nothing. Without per-chip
figures the ranking falls back to network totals as before.
