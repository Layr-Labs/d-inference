package attempt

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// timingMsBetween returns the elapsed milliseconds between two request-lifecycle
// timestamps, or 0 when either endpoint is unset or the interval is non-positive.
// It keeps the latency-decomposition fields defensive: never a negative value,
// never a panic on a zero timestamp.
func TimingMsBetween(a, b time.Time) float64 {
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
func ApplyTimingDecomposition(out *store.InferenceRouteOutcome, t *registry.RequestTiming, firstChunk time.Time) {
	if out == nil || t == nil {
		return
	}
	out.ParseMs = TimingMsBetween(t.ReceivedAt, t.ParsedAt)
	out.ReserveMs = TimingMsBetween(t.ParsedAt, t.ReservedAt)
	// Remote-media fetch (when it happened) sits between ReservedAt and
	// RoutedAt; anchor the route segment past it so a multi-second download
	// doesn't masquerade as routing latency. The fetch duration itself is
	// reported via the X-Timing header and DD histogram (no outcome column).
	routeAnchor := t.ReservedAt
	if !t.MediaFetchedAt.IsZero() {
		routeAnchor = t.MediaFetchedAt
	}
	out.RouteMs = TimingMsBetween(routeAnchor, t.RoutedAt)
	out.EncryptMs = TimingMsBetween(t.RoutedAt, t.EncryptedAt)
	out.QueueWaitMs = TimingMsBetween(t.QueuedAt, t.DispatchedAt)
	out.DispatchMs = TimingMsBetween(t.DispatchedAt, firstChunk)
}
