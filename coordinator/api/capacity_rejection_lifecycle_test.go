package api

// Follow-up coverage for the capacity-reject cooldown (PR #507 P2s):
//   1. the generic (/v1/completions, /v1/messages) path records the ACCEPT at
//      first content, so a long generic stream on a busy box keeps vouching
//      for the pair while it sheds concurrent dispatches;
//   2. cold 404 "model not loaded" misses strike (a box that 404s forever is
//      a black hole) while the normal 404-then-load-then-serve lifecycle
//      never trips (the accept resets the streak);
//   3. an ALL-COOLED model surfaces as TRANSIENT capacity — a preflight 429
//      with Retry-After and zero provider dispatches — not a structural
//      "no providers" 503.
// The half-open single-probe semantics are covered in
// registry/capacity_cooldown_test.go (claim lifecycle + concurrency).
