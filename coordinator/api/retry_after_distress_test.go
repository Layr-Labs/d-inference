package api

// estimateRetryAfter distress-scaling tests (2026-09-01 congestion collapse).
//
// Queue depth alone was a liar under CPU saturation: the queue was empty
// (nothing could reach it), so every 429 carried "Retry-After: 2" and
// upstream retried every 2s, sustaining the death loop. When the attempt-0
// route-latency EWMA shows routing itself is degraded (> 1s), the answer
// must scale with the observed degradation — max(base, ceil(EWMA_s)*5),
// capped at 60 — while healthy routing keeps the legacy queue-depth values.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestEstimateRetryAfter_DistressScaling(t *testing.T) {
	t.Run("healthy keeps legacy empty-queue answer", func(t *testing.T) {
		srv, _ := testServer(t)
		if got := srv.estimateRetryAfter("m"); got != 2 {
			t.Fatalf("healthy empty-queue Retry-After = %d, want legacy 2", got)
		}
		// Sub-threshold degradation (EWMA <= 1s) changes nothing.
		srv.noteAttempt0RouteLatency(800 * time.Millisecond)
		if got := srv.estimateRetryAfter("m"); got != 2 {
			t.Fatalf("sub-threshold EWMA Retry-After = %d, want legacy 2", got)
		}
	})

	t.Run("degraded EWMA scales at least 5x", func(t *testing.T) {
		srv, _ := testServer(t)
		// The incident shape: attempt-0 route p50 at 4.6s.
		srv.noteAttempt0RouteLatency(4600 * time.Millisecond)
		got := srv.estimateRetryAfter("m")
		if want := 25; got != want { // ceil(4.6)*5
			t.Fatalf("degraded Retry-After = %d, want %d (ceil(4.6s)*5)", got, want)
		}
		if got < 5*2 {
			t.Fatalf("degraded Retry-After = %d, want >= 5x the healthy answer", got)
		}
	})

	t.Run("distress answer caps at 60", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.noteAttempt0RouteLatency(90 * time.Second)
		if got := srv.estimateRetryAfter("m"); got != maxDistressRetryAfter {
			t.Fatalf("capped Retry-After = %d, want %d", got, maxDistressRetryAfter)
		}
	})

	t.Run("healthy samples pull a degraded EWMA back to legacy", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.noteAttempt0RouteLatency(4600 * time.Millisecond)
		for i := 0; i < 15; i++ { // 4600 * 0.8^15 ≈ 162ms
			srv.noteAttempt0RouteLatency(40 * time.Millisecond)
		}
		if got := srv.estimateRetryAfter("m"); got != 2 {
			t.Fatalf("recovered Retry-After = %d, want legacy 2 (EWMA=%.0fms)",
				got, srv.attempt0RouteEWMAMs())
		}
	})

	t.Run("negative samples are dropped", func(t *testing.T) {
		srv, _ := testServer(t)
		srv.noteAttempt0RouteLatency(-5 * time.Second)
		if got := srv.attempt0RouteEWMAMs(); got != 0 {
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
	if got := attempt0RouteAnchor(nil); !got.IsZero() {
		t.Fatalf("nil timing anchor = %v, want zero", got)
	}
	reservedOnly := &registry.RequestTiming{ReceivedAt: now.Add(-10 * time.Second), ReservedAt: now}
	if got := attempt0RouteAnchor(reservedOnly); !got.Equal(now) {
		t.Fatalf("anchor = %v, want ReservedAt", got)
	}
	withMedia := &registry.RequestTiming{
		ReceivedAt:     now.Add(-10 * time.Second),
		ReservedAt:     now.Add(-5 * time.Second),
		MediaFetchedAt: now,
	}
	if got := attempt0RouteAnchor(withMedia); !got.Equal(now) {
		t.Fatalf("anchor = %v, want MediaFetchedAt past the fetch", got)
	}
}

// TestNoteAttempt0RouteLatency_IgnoresMediaFetchTime drives the REAL funnel
// (dispatchOneProvider) with a request that spent ~10s receiving/parsing and
// fetching media but only ~80ms between the media fetch and routing. The
// recorded EWMA sample must reflect the ~80ms route segment — a
// ReceivedAt-anchored sample (~10s) would trip the distress threshold on
// media traffic alone.
func TestNoteAttempt0RouteLatency_IgnoresMediaFetchTime(t *testing.T) {
	srv, _ := testServer(t)
	const model = "ewma-anchor-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})
	registerBuildsProvider(srv, "ewma-anchor-provider", model)

	now := time.Now()
	timing := &registry.RequestTiming{
		ReceivedAt:     now.Add(-10 * time.Second),
		ParsedAt:       now.Add(-9 * time.Second),
		ReservedAt:     now.Add(-8 * time.Second),
		MediaFetchedAt: now.Add(-80 * time.Millisecond),
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	// 15s deadline keeps the 10s-old absolute clock dispatchable; the nil-conn
	// provider write fails AFTER RoutedAt is stamped, which is all we need.
	srv.dispatchOneProvider(
		r, model, model, []byte(`{"model":"`+model+`"}`), "test-key", nil,
		0, 6, 15*time.Second, 64, registry.TokenAdmission{}, false,
		registry.RequestTraits{}, nil, false, selfRoutePolicy{}, timing,
		false, registry.CachePlan{}, map[string]struct{}{}, 0, nil, "", nil, nil)

	got := srv.attempt0RouteEWMAMs()
	if got <= 0 {
		t.Fatal("no EWMA sample recorded — RoutedAt stamp did not feed the EWMA")
	}
	if got >= 1000 {
		t.Fatalf("EWMA sample = %.0fms — receive/parse/media time leaked into the route sample (anchor must be MediaFetchedAt)", got)
	}
}

// TestNoteAttempt0RouteLatency_RecordsFailedSelections pins the
// total-overload contract: when NO reservation ever succeeds (the collapse's
// terminal phase — every scan comes back empty), the failed attempt-0
// selection itself must feed the EWMA. An EWMA fed only by successful routes
// would sit at 0 and keep Retry-After at the legacy 2s exactly when distress
// scaling matters most.
func TestNoteAttempt0RouteLatency_RecordsFailedSelections(t *testing.T) {
	srv, _ := testServer(t) // zero providers: every reservation fails
	now := time.Now()
	// The selection has been grinding for ~4.6s (the incident's route p50)
	// when it finally fails.
	timing := &registry.RequestTiming{
		ReceivedAt: now.Add(-4600 * time.Millisecond),
		ReservedAt: now.Add(-4600 * time.Millisecond),
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	_, _, _, _, lastErr, _ := srv.dispatchOneProvider(
		r, "overload-model", "overload-model", []byte(`{"model":"overload-model"}`),
		"test-key", nil, 0, 6, 15*time.Second, 64, registry.TokenAdmission{},
		false, registry.RequestTraits{}, nil, false, selfRoutePolicy{}, timing,
		false, registry.CachePlan{}, map[string]struct{}{}, 0, nil, "", nil, nil)
	if lastErr != "no provider available" {
		t.Fatalf("lastErr = %q, want the empty-fleet failure", lastErr)
	}
	if got := srv.attempt0RouteEWMAMs(); got < 4000 {
		t.Fatalf("EWMA after failed selection = %.0fms, want the ~4600ms selection duration recorded", got)
	}
	if got := srv.estimateRetryAfter("overload-model"); got < 10 {
		t.Fatalf("Retry-After under total overload = %d, want the distress-scaled value (>= 5x legacy)", got)
	}
}
