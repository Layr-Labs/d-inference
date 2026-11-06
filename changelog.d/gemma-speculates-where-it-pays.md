### Gemma speculates where it pays

- On one Mac, Gemma 4 26B QAT now chooses how far ahead to draft, between none and four tokens, from how well the drafts are being accepted and how much a longer draft costs on that Mac. Greedy answers are unchanged; sampled answers keep the acceptance rule that `mtp_acceptance` sets.
- `/metrics` now shows how many decode steps ran at each draft depth (`mtp_depth_steps_total`) and how Gemma's probes turned out (`mtp_probe_windows_total`).
