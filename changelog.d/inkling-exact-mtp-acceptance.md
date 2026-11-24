### Inkling 2 Mini accepts drafts exactly by default

Inkling 2 Mini's DSpark drafter now uses exact acceptance unless
`mtp_acceptance` or `mtp_acceptance_by_model` says otherwise. A draft is kept
only when it equals the token the model itself samples, so sampled requests
keep the model's own output distribution. Before, Inkling used typical
acceptance, which keeps the drafter's greedy proposals far more often than
sampling would. On OpenRouter's GPQA request shape at temperature 0.5, none of
8 drafter-on samples reached an answer (they repeated until the 32,768-token
output cap or the loop guard), while all 4 drafter-off samples of the same
questions answered correctly. Greedy requests are unchanged. Setting
`mtp_acceptance = "typical"` restores the previous rule.
