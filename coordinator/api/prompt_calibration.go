package api

// Prompt-token estimate calibration for the servability context gate.
//
// estimatePromptTokens (consumer.go) approximates prompt tokens as len/4. That
// UNDERcounts real tokenization: measured prod actual/estimate ratios are p50
// 1.19, p90 ~2.1, max ~5.9 (dense code/JSON tokenizes far below 4 chars/token).
// Uncalibrated, a request whose exact prompt exceeds the model context window
// looks small enough to pass the context tier (est+max < context), gets
// dispatched, and the provider 503s with token_budget_exhausted. A conservative
// per-family multiplier nudges the gate's input up so those are caught at
// preflight (uptime-neutral 429, no dispatch). It is deliberately kept BELOW the
// observed p90 so genuinely-servable mid-size prompts are not over-rejected — the
// always-on dispatch-time deterministic stop (dispatch.go shouldStopFailover) is
// the exact backstop for everything the estimate still misses.
//
// Applied to the servability context check and first-content prompt-work
// estimate. Billing and physical token reservations retain their existing inputs.
// This is family-level evidence, not a per-template tokenizer guarantee; exact
// cache-planner token counts supersede it, and uncertain forecasts remain unknown.
