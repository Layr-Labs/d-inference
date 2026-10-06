package inference_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestPlanRefreshRetainsNewAlternates(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "plan-refresh-model"
	for i := range 2 {
		planWiringProvider(t, s.registry, fmt.Sprintf("initial-%d", i), model, int64(i)*400)
	}
	initial := planWiringPlan(t, s.registry, model)
	plan := s.NewDispatcher().NewPlan(initial)
	excluded := dispatch.NewExclusions()
	var selected string
	in := dispatch.Input{
		Request: httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil),
		Model:   model, PublicModel: model, Body: []byte(`{"model":"` + model + `"}`),
		Deadline: 5 * time.Second, Timing: &registry.RequestTiming{ReceivedAt: time.Now()},
		Exclusions: excluded, Forecast: firstcontent.NewForecast(estimate.NewContextCalibration(), excluded.Exclude),
		RecordRoute: func(provider *registry.Provider, _ *registry.PendingRequest, _ registry.RoutingDecision) {
			selected = provider.ID
		},
	}
	if out, source := plan.Next(in); source != dispatch.PlanRetained || out.Error != "failed to send request to provider" {
		t.Fatalf("initial retained dispatch = %+v, source=%v", out, source)
	}
	if initial.Remaining() != 0 {
		t.Fatal("initial plan was not exhausted")
	}
	for i := range 3 {
		planWiringProvider(t, s.registry, fmt.Sprintf("fresh-%d", i), model, int64(i)*400)
	}
	remaining := map[string]bool{"fresh-0": true, "fresh-1": true, "fresh-2": true}
	var fresh *registry.DispatchPlan
	for i := range 3 {
		out, source := plan.Next(in)
		wantSource := dispatch.PlanRetained
		if i == 0 {
			wantSource = dispatch.PlanRefreshed
			fresh = out.Plan
			if fresh == nil {
				t.Fatal("refresh did not return its new plan")
			}
		}
		if source != wantSource || !remaining[selected] || out.Error != "failed to send request to provider" {
			t.Fatalf("fresh dispatch %d: selected=%q source=%v result=%+v", i, selected, source, out)
		}
		// Reservation re-ranks retained identities against current evidence;
		// its winner need not be the scan-time PeekNext entry.
		if got := fresh.Remaining(); got != 2-i {
			t.Fatalf("fresh dispatch %d consumed a different plan: remaining=%d", i, got)
		}
		delete(remaining, selected)
	}
	// A new fallback scan may find more providers, but must not resurrect the
	// spent plan or grant a second request-wide refresh.
	for i := range 2 {
		planWiringProvider(t, s.registry, fmt.Sprintf("fallback-%d", i), model, int64(i)*400)
	}
	if _, source := plan.Next(in); source != dispatch.PlanExhausted {
		t.Fatalf("spent refresh source=%v, want exhausted", source)
	}
	if out := plan.Scan(in); out.Plan == nil || out.Plan.Remaining() == 0 {
		t.Fatalf("fallback scan did not produce fresh alternates: %+v", out)
	}
	if _, source := plan.Next(in); source != dispatch.PlanExhausted {
		t.Fatalf("fallback scan resurrected plan: source=%v", source)
	}
}
