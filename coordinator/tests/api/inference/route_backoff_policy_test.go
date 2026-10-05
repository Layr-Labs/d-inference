package inference_test

import (
	"testing"
	"time"

	backoff "github.com/eigeninference/d-inference/coordinator/internal/inference/backoff"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestEstimateRetryAfter_DistressScaling(t *testing.T) {
	t.Run("healthy keeps legacy empty-queue answer", func(t *testing.T) {
		srv, _ := testServer(t)
		if got := srv.backoff.Estimate("m"); got != 2 {
			t.Fatalf("healthy empty-queue Retry-After = %d, want legacy 2", got)
		}
		// Sub-threshold degradation (EWMA <= 1s) changes nothing.
		srv.backoff.NoteRouteLatency(800 * time.Millisecond)
		if got := srv.backoff.Estimate("m"); got != 2 {
			t.Fatalf("sub-threshold EWMA Retry-After = %d, want legacy 2", got)
		}
	})

	t.Run("degraded EWMA scales at least 5x", func(t *testing.T) {
		srv, _ := testServer(t)
		// The incident shape: attempt-0 route p50 at 4.6s.
		srv.backoff.NoteRouteLatency(4600 * time.Millisecond)
		got := srv.backoff.Estimate("m")
		if want := 25; got != want { // ceil(4.6)*5
			t.Fatalf("degraded Retry-After = %d, want %d (ceil(4.6s)*5)", got, want)
		}
		if got < 5*2 {
			t.Fatalf("degraded Retry-After = %d, want >= 5x the healthy answer", got)
		}
	})

	t.Run("distress answer caps at 60", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.backoff.NoteRouteLatency(90 * time.Second)
		if got := srv.backoff.Estimate("m"); got !=
			backoff.MaxDistressRetryAfter {
			t.Fatalf("capped Retry-After = %d, want %d", got, backoff.MaxDistressRetryAfter)
		}
	})

	t.Run("healthy samples pull a degraded EWMA back to legacy", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.backoff.NoteRouteLatency(4600 * time.Millisecond)
		for i := 0; i < 15; i++ { // 4600 * 0.8^15 ≈ 162ms
			srv.backoff.NoteRouteLatency(40 * time.Millisecond)
		}
		if got := srv.backoff.Estimate("m"); got != 2 {
			t.Fatalf("recovered Retry-After = %d, want legacy 2 (EWMA=%.0fms)",
				got, srv.backoff.RouteEWMAMs())
		}
	})

	t.Run("negative samples are dropped", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.backoff.NoteRouteLatency(-5 * time.Second)
		if got := srv.backoff.RouteEWMAMs(); got != 0 {
			t.Fatalf("EWMA after negative sample = %v, want 0", got)
		}
	})
}

// TestAttempt0RouteAnchor pins the EWMA sample anchor to the SAME instant
// applyTimingDecomposition anchors route_ms: MediaFetchedAt when a remote
// media fetch happened, else ReservedAt — never ReceivedAt/ParsedAt, so a
// multi-second download or slow parse can never fake routing distress.
func TestAttempt0RouteAnchor(t *testing.T) {
	now := time.Now()
	if got := backoff.RouteAnchor(nil); !got.IsZero() {
		t.Fatalf("nil timing anchor = %v, want zero", got)
	}
	reservedOnly := &registry.RequestTiming{ReceivedAt: now.Add(-10 * time.Second), ReservedAt: now}
	if got := backoff.RouteAnchor(reservedOnly); !got.Equal(now) {
		t.Fatalf("anchor = %v, want ReservedAt", got)
	}
	withMedia := &registry.RequestTiming{
		ReceivedAt:     now.Add(-10 * time.Second),
		ReservedAt:     now.Add(-5 * time.Second),
		MediaFetchedAt: now,
	}
	if got := backoff.RouteAnchor(withMedia); !got.Equal(now) {
		t.Fatalf("anchor = %v, want MediaFetchedAt past the fetch", got)
	}
}
