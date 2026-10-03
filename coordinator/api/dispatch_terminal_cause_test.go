package api

// Regression tests for the PR review findings on typed-terminal handling in
// the dispatch ladder: the typed fields must survive setLastInferenceError so
// (1) a typed admission_timeout is classified as transient capacity by
// shouldStopFailover even though its fixed error text matches none of the
// legacy capacity substrings, and (2) typed attempt_usage reaches the failed
// attempt's route row on the ordinary (waitFirstChunk/waitAccepted) path,
// which builds its outcome from dispatch state rather than the standalone
// constructors.
