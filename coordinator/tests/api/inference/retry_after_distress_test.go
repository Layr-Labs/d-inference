package inference_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	dispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

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
	srv.NewDispatcher().Dispatch(
		r, model, model, []byte(`{"model":"`+model+`"}`), "test-key", nil,
		0, 6, 15*time.Second, 64, registry.TokenAdmission{}, false,
		registry.RequestTraits{}, nil, false, dispatch.Scope{}, timing,
		false, registry.CachePlan{}, dispatch.NewExclusions(), 0, nil, "", nil, nil, true, srv.NewDispatcher().ScanReserver(model),
	)

	got := srv.backoff.RouteEWMAMs()
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
	_, _, _, _, lastErr, _ := srv.NewDispatcher().Dispatch(
		r, "overload-model", "overload-model", []byte(`{"model":"overload-model"}`),
		"test-key", nil, 0, 6, 15*time.Second, 64, registry.TokenAdmission{},
		false, registry.RequestTraits{}, nil, false, dispatch.Scope{}, timing,
		false, registry.CachePlan{}, dispatch.NewExclusions(), 0, nil, "", nil, nil, true, srv.NewDispatcher().ScanReserver("overload-model"),
	)
	if lastErr != "no provider available" {
		t.Fatalf("lastErr = %q, want the empty-fleet failure", lastErr)
	}
	if got := srv.backoff.RouteEWMAMs(); got < 4000 {
		t.Fatalf("EWMA after failed selection = %.0fms, want the ~4600ms selection duration recorded", got)
	}
	if got := srv.backoff.Estimate("overload-model"); got < 10 {
		t.Fatalf("Retry-After under total overload = %d, want the distress-scaled value (>= 5x legacy)", got)
	}
}
