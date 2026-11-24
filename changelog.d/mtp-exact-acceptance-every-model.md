### Every drafting model accepts drafts exactly by default

Without an `mtp_acceptance` setting, every model now uses exact draft
acceptance: a draft is kept only when it equals the token the model itself
samples, so sampled requests keep the model's own output distribution. Before,
only a list of builds was exact and the rest used typical acceptance. Typical
acceptance looped sampled answers on every family measured with it (Qwen 3.5
9B, Gemma 4 26B QAT, Inkling 2 Mini). Served families whose sampled requests
change: GLM-5.3-Flash and Qwen 4 where served. Nemotron does not draft by
default, native MiMo was already exact, and greedy requests are unchanged
under either rule. `mtp_acceptance = "typical"`, globally or per model in
`mtp_acceptance_by_model`, still selects typical acceptance.
