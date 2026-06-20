package api

import "strings"

// isCapacityClassProviderError reports whether a provider inference-error string
// names a CAPACITY/LIFECYCLE condition rather than a genuine server fault. The
// request was admitted (or the model was being (re)loaded) and then rejected
// because the provider was momentarily unable to serve it: a token-budget /
// KV-cache / context overflow, OOM, a slot cap, an update drain, queue/overload
// backpressure, or a cold "model not loaded" miss.
//
// Split intent: provider 5xx are NOT blanket-reclassified. A crash is OUR
// failure and must stay 5xx; only capacity-class conditions become a 429.
//
//   - BUCKET A — capacity/lifecycle ⇒ return TRUE. When the dispatch path
//     exhausts all attempts with such an error, the coordinator reclassifies the
//     provider's raw 5xx to an uptime-NEUTRAL 429: OpenRouter treats 429 as
//     rate-limiting (no uptime penalty) and fails over, whereas a 5xx counts
//     against our uptime. It fires only on an ACTUAL provider rejection, so it
//     carries no over-rejection risk.
//
//   - BUCKET B — genuine fault ⇒ return FALSE. Crashes/panics, internal /
//     engine / backend failures, a "model load failed" (bad weights/metallib),
//     and the opaque Foundation-bridged InferenceError stay 5xx so they remain
//     visible on reliability metrics and a per-provider circuit breaker can
//     deroute the offender.
//
// The DEFAULT for unknown/ambiguous strings is FALSE (fault) so a newly-observed
// crash string stays visible until it is explicitly triaged.
//
// Matching is substring + case-insensitive because the strings are
// human-readable and drift across provider versions; it mirrors the provider's
// scheduler/loader reject strings ("token_budget_exhausted: …", "insufficient
// global kv cache headroom", "provider draining for update", "model load failed:
// …"). To classify a newly-observed string, drop it into capacityClassMarkers
// (A) or faultClassMarkers (B) — each bucket lives in ONE place, with a handful
// of non-substring predicates (whole-word "oom", "exceeds"+"context", slot-cap)
// handled explicitly below.
func isCapacityClassProviderError(errStr string) bool {
	s := strings.ToLower(strings.TrimSpace(errStr))
	if s == "" {
		return false
	}
	// Normalise the curly apostrophe (U+2019) that macOS Foundation emits in
	// "The operation couldn't be completed. …" so the BUCKET B marker below —
	// written with a plain ASCII apostrophe — matches the real wire string.
	s = strings.ReplaceAll(s, "\u2019", "'")

	// Unambiguous HARD faults (crash / panic / internal / opaque) are checked
	// FIRST so they always win — never a capacity shed even if the message
	// mentions memory. NOTE: "model load failed" is deliberately NOT in this set;
	// it is checked LATER (after the capacity markers) so a cold-load CAPACITY
	// failure the provider wraps as "model load failed: insufficient memory"
	// reclassifies to a 429, while a bad-weights load failure still falls through
	// to a 5xx fault.
	for _, m := range faultClassMarkers {
		if strings.Contains(s, m) {
			return false
		}
	}

	// BUCKET A (capacity/lifecycle) plain-substring markers ⇒ reclassify 5xx→429.
	for _, m := range capacityClassMarkers {
		if strings.Contains(s, m) {
			return true
		}
	}

	// BUCKET A predicates that need more than a plain substring.
	switch {
	case containsWord(s, "oom"):
		// Whole-word "oom" only, so "boom" / "no room left" do NOT match.
		return true
	case strings.Contains(s, "exceeds") && strings.Contains(s, "context"):
		// "prompt exceeds … context window/length" phrasings.
		return true
	case strings.Contains(s, "slot") &&
		(strings.Contains(s, "active") || strings.Contains(s, "cap")):
		// "All N model slot(s) are active; cannot load '…'" — slot-cap rejection.
		return true
	}

	// "model load failed: …" is checked AFTER the capacity markers above, so a
	// transient cold-load CAPACITY failure the provider wraps as "model load
	// failed: insufficient memory / insufficient KV / all N slot(s) active"
	// already reclassified to 429 above. Reaching here means a "model load
	// failed" with NO capacity reason — a genuine load fault (bad weights /
	// metallib / corrupt model) — so it stays a 5xx.
	if strings.Contains(s, "model load failed") {
		return false
	}

	// DEFAULT: unknown/ambiguous ⇒ genuine fault (keep 5xx, stays visible).
	return false
}

// capacityClassMarkers are BUCKET A substrings: ADMITTED-but-unservable or
// lifecycle rejections that should reclassify a provider 5xx to an uptime-neutral
// 429. Drop a newly-observed capacity string here (predicates that need more than
// a substring — whole-word "oom", "exceeds"+"context", slot-cap — live in
// isCapacityClassProviderError). Keep each marker specific enough that it never
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
	// isCapacityClassProviderError AFTER the capacity markers, so a cold-load
	// capacity failure ("model load failed: insufficient memory") reclassifies to
	// 429 while a bad-weights load failure falls through to the default fault.
}
