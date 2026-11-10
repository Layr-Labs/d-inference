### Speculative decoding no longer changes what a model says

- Every model now drafts with exact acceptance unless `mtp_acceptance` or `mtp_acceptance_by_model` says `typical`: a sampled request gets the model's own output distribution, with or without speculation. Before, every model but the Bonsai 9B candidate and `Qwen3.5-9B` used lossy typical acceptance by default.
- Typical acceptance keeps drafts the model would rarely have sampled, and once a repetition starts the drafter predicts it and it is kept. In the 0.10.12 gate the catalog Qwen 3.5 builds looped under it where exact acceptance did not (Qwen3.5-9B: 13 of 31 draws against 0 of 31), and on OpenRouter's GPQA runs drafted answers ran to the output cap far more often (Qwen 3.6: 36 % of answers while it drafted, 9 % once it stopped; Gemma 4: 30 %).
- Exact acceptance keeps fewer drafts, so speculative decoding speeds a stream up less; `mtp_acceptance = "typical"` restores the old rule for operators who accept the trade.
