package api

// Attempt-usage observability (deadline incident fix): a typed error terminal
// can carry the engine-reconciled partial usage of the failed attempt
// (InferenceErrorMessage.AttemptUsage). The coordinator persists those token
// counts on the route row — the incident's "every strict route had null
// prompt_tokens/completion_tokens" gap — WITHOUT touching billing: refunds,
// reservations, earnings, and cost stay exactly as for a usage-less error.
