package api

// provider_body_memo.go memoizes, for ONE request, the provider-bound body of
// each candidate model and the routing verdicts derived from it. The chat
// handler needs that body for the resolved build (dispatch), for the alias
// fallback build the admission preflight probes, and again for the size
// verdict and routing traits of whichever build wins — and every one of those
// used to rebuild and re-serialize the body from scratch. Building is a full
// marshal (plus a parse+re-encode for the legacy cache-bust sizing), so a
// single request paid it three to five times for the same bytes.
