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

// rejectionKind refines a CAPACITY-class provider rejection by how the dispatch
// loop should respond. isCapacityClassProviderError only answers the 5xx→429
// question; this answers the orthogonal "should we keep failing over?" question.
//
// A request that is intrinsically too large for the MODEL (its prompt exceeds
// the context window / per-batch prompt cap) is rejected identically by EVERY
// provider serving that model — so retrying across the fleet is pure waste. In
// prod this produced a 22-63× dispatch storm (ceiling maxDispatchAttempts=64),
// ~8.7 min latency per request, and 0% eventual success. Those stop after the
// first rejection. A provider/time-specific shortage (this node's live KV
// budget, a full queue, an update drain, a cold miss) MAY clear on another
// provider, so those still fail over — but under a tight cap so a fleet-wide
// transient can't storm either.
type rejectionKind int

const (
	// rejectionNotCapacity: a genuine fault (or unrecognised string) — the caller
	// keeps existing behavior (stays a 5xx fault, the per-provider breaker may
	// deroute the offender, and fault failover continues to maxDispatchAttempts).
	rejectionNotCapacity rejectionKind = iota
	// rejectionDeterministicUnservable: the request exceeds the model's context /
	// per-batch prompt limit — identical on every provider. Stop immediately and
	// return an uptime-neutral 429; retrying cannot help.
	rejectionDeterministicUnservable
	// rejectionTransientCapacity: a provider/time-specific shortage. Failover may
	// help, bounded by maxCapacityClassRetries.
	rejectionTransientCapacity
)

// classifyRejection refines a pre-content provider error into the dispatch
// response kind. reason is the structured InferenceErrorMessage.ErrorReason
// (may be empty); errStr is the human-readable provider error. providerBudget is
// the rejecting provider's most recently reported token budget for the model
// (ActiveTokenBudgetMax, 0 = unknown); modelContext is the model's context window
// (0 = unknown). A non-capacity error returns rejectionNotCapacity so callers
// preserve fault failover + the per-provider breaker. Matching mirrors
// isCapacityClassProviderError (substring, case-insensitive,
// curly-apostrophe-normalised).
//
// providerBudget/modelContext exist to fix the unsound assumption that EVERY
// "batch token budget" rejection is fleet-wide deterministic. The provider's
// admission cap is min(context, activeTokenBudget) (BatchScheduler.swift
// resolvedMaxTokensPerBatch), and activeTokenBudget is memory-aware: under
// pressure it drops BELOW the context window. So the bare string can mean either
// "prompt > context" (deterministic — every provider rejects) or "prompt > THIS
// node's shrunk KV budget" (transient — a healthier provider serves). We treat it
// as deterministic UNLESS we have positive evidence of memory pressure on the
// rejecting provider (its reported budget is known and below the model context),
// in which case it is transient. An explicit "exceeds … context" phrasing names
// the context directly and is always deterministic.
//
// LIMITATION (residual stale-snapshot edge): providerBudget is the LAST
// heartbeat's ActiveTokenBudgetMax, not the live budget the provider rejected
// against — the wire InferenceErrorMessage carries no rejection-time budget. So if
// a provider's budget was >= context at the last heartbeat but memory pressure
// shrank it below context just before this request, we still classify
// deterministic and stop after one attempt. This is strictly better than the
// pre-DAR-347 behavior (which classified EVERY batch-budget rejection
// deterministic) and degrades only to a rare uptime-neutral 429 the client
// retries — never a 503 storm. The complete fix is provider-side: emit a distinct
// reason for "prompt > context" vs "prompt > this node's budget" so the
// coordinator never has to infer it from a stale snapshot (tracked as a follow-up;
// requires a protocol/provider change across a mixed fleet, out of scope here).
func classifyRejection(reason, errStr string, providerBudget int64, modelContext int) rejectionKind {
	// Capacity-class is gated by isCapacityClassProviderError so fault strings
	// (checked first there) can never be miscategorised as a capacity shed.
	if !isCapacityClassProviderError(errStr) && !isCapacityClassProviderError(reason) {
		return rejectionNotCapacity
	}
	s := strings.ToLower(strings.TrimSpace(errStr + " " + reason))
	s = strings.ReplaceAll(s, "’", "'")
	// An explicit context-window/length overflow names the model context directly —
	// unambiguous, fleet-wide deterministic regardless of any provider's KV budget.
	// Match BOTH tenses ("exceeds"/"exceeded") and the bare "context length" /
	// "context window" markers (mirrored in capacityClassMarkers and the provider
	// breaker), so phrasings like "context length exceeded" / "context window
	// exceeded" / "prompt too long for context window" stop on the first provider
	// instead of failing over. Retrying cannot help.
	if strings.Contains(s, "context") &&
		(strings.Contains(s, "exceeds") || strings.Contains(s, "exceeded")) {
		return rejectionDeterministicUnservable
	}
	if strings.Contains(s, "context length") || strings.Contains(s, "context window") {
		return rejectionDeterministicUnservable
	}
	// "request exceeds batch token budget" (BatchSchedulerTypes:
	// requestExceedsBatchTokenBudget) is rejected at min(context, activeTokenBudget).
	// Deterministic ONLY when we can rule out that this node was memory-pressured:
	// a known reported budget below the model context means the binding term may
	// have been THIS node's KV budget, so a less-pressured provider could serve —
	// treat as transient (failover, capped). Otherwise (budget >= context, or
	// either value unknown) the binding term is the context, identical fleet-wide.
	if strings.Contains(s, "batch token budget") {
		if modelContext > 0 && providerBudget > 0 && providerBudget < int64(modelContext) {
			return rejectionTransientCapacity
		}
		return rejectionDeterministicUnservable
	}
	// Everything else capacity-class is provider/time-specific — this node's live
	// KV budget ("exceeds active token budget" / "requires N tokens but only M
	// available" / "insufficient kv headroom"), a full queue, server busy, an
	// update drain, or a cold "not loaded" miss. Another provider (bigger budget,
	// free queue, already warm) may serve it, so fail over under the cap.
	return rejectionTransientCapacity
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
