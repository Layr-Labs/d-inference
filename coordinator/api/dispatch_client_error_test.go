package api

// C1: a deterministic provider client-shape 4xx must STOP failover immediately
// (return the code once) instead of walking up to maxDispatchAttempts providers.
