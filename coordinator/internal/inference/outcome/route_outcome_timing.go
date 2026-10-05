package outcome

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// timingMsBetween returns the elapsed milliseconds between two request-lifecycle
// timestamps, or 0 when either endpoint is unset or the interval is non-positive.
// It keeps the latency-decomposition fields defensive: never a negative value,
// never a panic on a zero timestamp.
func timingMsBetween(a, b time.Time) float64 {
	if a.IsZero() || b.IsZero() || !b.After(a) {
		return 0
	}
	return float64(b.Sub(a).Milliseconds())
}

// applyTimingDecomposition fills the coordinator-side latency-decomposition
// fields (ParseMs..DispatchMs) on a routing outcome from the per-request timing
// stamps. Each segment is populated only when both of its endpoints are set
// (timingMsBetween returns 0 otherwise), so a partially-instrumented request
// never records a negative or bogus segment. QueueWaitMs is 0 for requests that
// were dispatched without queueing (QueuedAt unset).
//
// firstChunk is passed in (not read from t.FirstChunkAt) so this can also be
// called from the provider read-loop goroutine (handleComplete) with a value
// obtained via PendingRequest.FirstChunkAtSafe; t.FirstChunkAt itself must only
// be read directly by the dispatch goroutine that owns the request.
func applyTimingDecomposition(out *store.InferenceRouteOutcome, t *registry.RequestTiming, firstChunk time.Time) {
	if out == nil || t == nil {
		return
	}
	out.ParseMs = timingMsBetween(t.ReceivedAt, t.ParsedAt)
	out.ReserveMs = timingMsBetween(t.ParsedAt, t.ReservedAt)
	// Remote-media fetch (when it happened) sits between ReservedAt and
	// RoutedAt; anchor the route segment past it so a multi-second download
	// doesn't masquerade as routing latency. The fetch duration itself is
	// reported via the X-Timing header and DD histogram (no outcome column).
	routeAnchor := t.ReservedAt
	if !t.MediaFetchedAt.IsZero() {
		routeAnchor = t.MediaFetchedAt
	}
	out.RouteMs = timingMsBetween(routeAnchor, t.RoutedAt)
	out.EncryptMs = timingMsBetween(t.RoutedAt, t.EncryptedAt)
	out.QueueWaitMs = timingMsBetween(t.QueuedAt, t.DispatchedAt)
	out.DispatchMs = timingMsBetween(t.DispatchedAt, firstChunk)
}

// isTerminalClientErrorCode reports whether a provider-returned status code is a
// DETERMINISTIC client-shape rejection that fails identically on every provider,
// so the dispatch loop must stop and return it ONCE rather than fail over.
//
// Set: 400 (invalidRole / invalidToolPayload / mediaUnsupportedByModel + all VLM
// client MediaError), plus 413/415 defensively (unambiguous client shapes; not
// emitted by the provider map today but correct if a future version does).
//
// EXCLUDES 422 deliberately: the provider maps invalidResponseFormatOutput→422,
// which is thrown for BOTH a deterministic request-shape fault ("json_schema
// requires a json_schema payload") AND a model-OUTPUT-validation fault ("model
// output was not valid JSON"). The latter depends on what the model GENERATED, so
// a re-sample at temperature>0 (or a different provider/model) could succeed —
// stopping it would turn a recoverable request into a lost success (hurting
// uptime). 422 therefore stays on the normal failover path.
//
// Also EXCLUDES 404 ("model not loaded" — a cold-miss/lifecycle that MUST fail
// over, and which matches the "not loaded" capacity marker), 408 and 429
// (transient). 402 (the only coordinator-emitted 4xx) is excluded, so a code in
// this set can ONLY originate from a provider InferenceErrorMessage.
func IsTerminalClientErrorCode(code int) bool {
	switch code {
	case http.StatusBadRequest, // 400
		http.StatusRequestEntityTooLarge, // 413
		http.StatusUnsupportedMediaType:  // 415
		return true
	}
	return false
}
