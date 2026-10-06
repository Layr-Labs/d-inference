package providerwire

// errFirstContentDeadlineExpired is returned when the request-absolute
// first-content clock runs out before an inference_request reaches the provider
// wire. No provider work was started, so callers surface a deadline 429 without
// charging provider health.
const DeadlineExpiredMessage = "first-content deadline expired before provider dispatch"
