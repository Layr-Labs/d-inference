### Gemma 4 26B QAT drafts with exact MTP acceptance

- The catalog `gemma-4-26b-qat-4bit` now uses exact draft acceptance by default: each token a speculating sampled request commits is the model's own draw, so its outputs follow the model's distribution (exact in distribution; the tokens are not bit-identical to decoding without MTP). Every other model keeps its built-in rule; the 8-bit Gemma builds draft only with `mtp_mode = "on"` and stay typical.
- Its assistant drafts most Gemma rows, and typical acceptance keeps drafts the model would rarely have sampled; once a repetition starts the drafter predicts it and it is kept. On OpenRouter's GPQA run of 10-31 every Gemma answer drafted under typical acceptance and 30 % ran to the 32,768-token cap with no answer.
- Exact keeps fewer drafts, so MTP speeds a Gemma stream up a little less (0.96x of typical at one request in the 10-07 measurements). `mtp_acceptance_by_model` with `"gemma-4-26b-qat-4bit" = "typical"` restores the old rule.
