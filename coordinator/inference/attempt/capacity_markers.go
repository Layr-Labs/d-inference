package attempt

// capacityClassMarkers are BUCKET A substrings: ADMITTED-but-unservable or
// lifecycle rejections that should reclassify a provider 5xx to an uptime-neutral
// 429. Drop a newly-observed capacity string here (predicates that need more than
// a substring — whole-word "oom", "exceeds"+"context", slot-cap — live in
// IsCapacityClassProviderError). Keep each marker specific enough that it never
// captures a BUCKET B fault string — notably use "not loaded" / "no model
// loaded", never a bare "load" / "loaded", so "model load failed" is NOT
// swallowed here.
var capacityClassMarkers = []string{
	// Token budget / KV-cache / context overflow (request too big to fit).
	"token_budget_exhausted",
	"token budget",
	"kv cache headroom",
	"kv headroom",
	"insufficient kv",
	"context length",
	"context window",
	// Memory pressure at load/serve time.
	"insufficient memory",
	"out of memory",
	// Update lifecycle: provider draining for a hot-swap restart
	// (protocol.ProviderDrainingForUpdate = "provider draining for update").
	"draining",
	// Overload / backpressure: the request was not run, so failover is safe.
	// NB: "service temporarily unavailable" is intentionally NOT a marker — the
	// coordinator itself emits "service temporarily unavailable — please retry"
	// on its OWN store/DB errors (e.g. a failed reservation top-up in the
	// dispatch path), which is a genuine coordinator fault that must stay a 5xx,
	// not be hidden as an uptime-neutral 429.
	"request rejected",
	"queue full",
	"server busy",
	"request timed out waiting for capacity",
	// Cold miss: model not resident yet. NOT "model load failed" (a fault) —
	// these markers match "model not loaded" / "is not loaded on this provider".
	"not loaded",
	"no model loaded",
}

// faultClassMarkers are BUCKET B substrings: genuine server faults that MUST stay
// 5xx so they surface on reliability metrics and the per-provider circuit breaker
// can deroute the offender. Drop a newly-observed crash/fault string here. Every
// marker must be specific enough that it never appears in a capacity string.
var faultClassMarkers = []string{
	"panic",          // PanicHook / telemetry .panic — process crash
	"fatal error",    // Swift fatalError / unrecoverable abort
	"backend crash",  // telemetry .backendCrash — engine/backend died
	"backend_crash",  // …and its wire-tag spelling
	"internal error", // generic server fault
	// Opaque Foundation-bridged InferenceError (no LocalizedError conformance):
	// "The operation couldn't be completed. (ProviderCore.InferenceError error N.)".
	"the operation couldn't be completed",
	// NOTE: "model load failed" is intentionally NOT here — it is checked in
	// IsCapacityClassProviderError AFTER the capacity markers, so a cold-load
	// capacity failure ("model load failed: insufficient memory") reclassifies to
	// 429 while a bad-weights load failure falls through to the default fault.
}
