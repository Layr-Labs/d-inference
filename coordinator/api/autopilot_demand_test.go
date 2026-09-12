package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func autopilotRequestFixture() (*http.Request, *autopilotDemandRequest, inferenceAdmissionParams) {
	d := &autopilotDemandRequest{sample: registry.AutopilotDemandSample{ReceivedAt: time.Now()}}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	r = r.WithContext(context.WithValue(r.Context(), autopilotDemandKey{}, d))
	return r, d, inferenceAdmissionParams{model: "model-build", estimatedPromptTokens: 27, requestedMaxTokens: 64}
}

func TestAutopilotDemandCountsOneLogicalRequestAcrossRetrySignals(t *testing.T) {
	r, d, p := autopilotRequestFixture()
	armAutopilotDemand(r, p)
	// Repeated annotations are not arrivals. Alias fallback must attribute the
	// single result to the final build even if initial admission chose another.
	for range 8 {
		annotateAutopilotDemandRejection(rejectionInfo{r: r, resolvedModel: p.model, reasonCode: "machine_busy", httpStatus: 429})
	}
	setAutopilotDemandModel(r, "fallback-build")
	annotateAutopilotDemandRejection(rejectionInfo{r: r, resolvedModel: "fallback-build", reasonCode: "queue_deadline", httpStatus: 429})
	sample, ok := d.finish(429, false)
	if !ok || sample.Model != "fallback-build" || !sample.CapacityShed || sample.Reason != "deadline" {
		t.Fatalf("wrong logical terminal: %+v, recorded=%v", sample, ok)
	}
	if sample.PromptTokens != 27 || sample.RequestedMaxTokens != 64 {
		t.Fatalf("honest short input was excluded or envelope changed: %+v", sample)
	}
	if _, ok := d.finish(429, false); ok {
		t.Fatal("logical request counted twice")
	}
}

func TestAutopilotDemandExcludesUnvalidatedAndScopedTraffic(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*inferenceAdmissionParams)
		arm    bool
		status int
	}{
		{"auth before admission", func(*inferenceAdmissionParams) {}, false, 401},
		{"account rate limit before admission", func(*inferenceAdmissionParams) {}, false, 429},
		{"validation after admission", func(*inferenceAdmissionParams) {}, true, 400},
		{"balance topup after admission", func(*inferenceAdmissionParams) {}, true, 402},
		{"self route", func(p *inferenceAdmissionParams) { p.policy.enabled = true }, true, 200},
		{"prefer owner", func(p *inferenceAdmissionParams) { p.policy.prefer = true }, true, 200},
		{"serial restricted", func(p *inferenceAdmissionParams) { p.allowedProviderSerials = []string{"private-serial"} }, true, 200},
		{"invalid prompt envelope", func(p *inferenceAdmissionParams) { p.estimatedPromptTokens = 0 }, true, 200},
		{"invalid output envelope", func(p *inferenceAdmissionParams) { p.requestedMaxTokens = -1 }, true, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, d, p := autopilotRequestFixture()
			tc.change(&p)
			if tc.arm {
				armAutopilotDemand(r, p)
			}
			if sample, ok := d.finish(tc.status, false); ok {
				t.Fatalf("non-public/non-valid arrival recorded: %+v", sample)
			}
		})
	}
}

func TestAutopilotDemandSeparatesCapacityFromIntrinsicAndCoordinatorLimits(t *testing.T) {
	for _, tc := range []struct {
		raw, reason string
		capacity    bool
		recorded    bool
	}{
		{"machine_busy", "capacity_shed", true, true},
		{"queue_timeout", "capacity_shed", true, true},
		{"first_chunk_timeout", "deadline", true, true},
		{"ttft_too_slow", "deadline", true, true},
		{"routing_saturated", "routing_saturated", false, true},
		{"context_exceeded", "intrinsic_unservable", false, true},
		{"oversized_request", "intrinsic_unservable", false, true},
		{"rate_limit_exceeded", "", false, false},
		{"provider-controlled secret", "", false, false},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			r, d, p := autopilotRequestFixture()
			armAutopilotDemand(r, p)
			annotateAutopilotDemandRejection(rejectionInfo{r: r, resolvedModel: p.model, reasonCode: tc.raw, httpStatus: 429})
			sample, ok := d.finish(429, false)
			if ok != tc.recorded || (ok && (sample.Reason != tc.reason || sample.CapacityShed != tc.capacity)) {
				t.Fatalf("terminal %+v recorded=%v; want reason=%q capacity=%v recorded=%v", sample, ok, tc.reason, tc.capacity, tc.recorded)
			}
		})
	}
}

func autopilotCompletedProfile() (*registry.RequestProfile, *registry.AttemptProfile) {
	rp := registry.NewRequestProfile(time.Now(), "test-only-id", nil, time.Second)
	rp.DoneFlushedUS.Store(20_000_000)
	// A failed/speculative attempt must never become a second service sample.
	loser := rp.NewAttempt("loser", 0, "")
	loser.ProviderCompleteObserved.Store(true)
	loser.SetOutcome("success", "", "", "completed", "")
	loser.SetTerminalUsage(9999, 9999)
	winning := rp.NewAttempt("winner", 1, "loser")
	winning.Winning.Store(true)
	winning.ProviderCompleteObserved.Store(true)
	winning.AcceptedUS.Store(5_000_000)
	winning.CompleteIngressUS.Store(15_000_000)
	winning.DecisionSet = true
	winning.SetOutcome("success", "", "", "completed", "")
	winning.SetTerminalUsage(25, 2)
	return rp, winning
}

func TestAutopilotDemandUsesOnlyCompletedWarmWinnerService(t *testing.T) {
	for _, tc := range []struct {
		name      string
		change    func(*registry.RequestProfile, *registry.AttemptProfile)
		completed bool
		service   time.Duration
	}{
		{"warm winner", func(*registry.RequestProfile, *registry.AttemptProfile) {}, true, 10 * time.Second},
		{"cold winner", func(_ *registry.RequestProfile, ap *registry.AttemptProfile) { ap.Decision.StateMs = 30000 }, true, 0},
		{"unknown placement", func(_ *registry.RequestProfile, ap *registry.AttemptProfile) { ap.DecisionSet = false }, true, 0},
		{"output incomplete", func(rp *registry.RequestProfile, _ *registry.AttemptProfile) { rp.DoneFlushedUS.Store(0) }, false, 0},
		{"write failed", func(rp *registry.RequestProfile, _ *registry.AttemptProfile) { rp.ClientWriteErr.Store(true) }, false, 0},
		{"provider terminal missing", func(_ *registry.RequestProfile, ap *registry.AttemptProfile) {
			ap.ProviderCompleteObserved.Store(false)
		}, false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, d, p := autopilotRequestFixture()
			armAutopilotDemand(r, p)
			rp, winner := autopilotCompletedProfile()
			tc.change(rp, winner)
			bindAutopilotDemandProfile(r, rp)
			sample, ok := d.finish(200, false)
			if !ok || sample.Completed != tc.completed || sample.ServiceTime != tc.service {
				t.Fatalf("bad completion sample %+v, recorded=%v", sample, ok)
			}
			if tc.completed && (sample.ObservedPromptTokens != 25 || sample.ObservedOutputTokens != 2) {
				t.Fatalf("winning usage lost or loser used: %+v", sample)
			}
		})
	}
}

func TestAutopilotDemandDepartureDoesNotClaimCapacityOrCompletion(t *testing.T) {
	r, d, p := autopilotRequestFixture()
	armAutopilotDemand(r, p)
	annotateAutopilotDemandRejection(rejectionInfo{r: r, reasonCode: "machine_busy", httpStatus: 429})
	sample, ok := d.finish(429, true)
	if !ok || sample.Reason != "client_departure" || sample.CapacityShed || sample.Completed || sample.ServiceTime != 0 {
		t.Fatalf("departed request attributed to a later terminal: %+v, recorded=%v", sample, ok)
	}
}

func TestAutopilotDemandHTTP499RetainsValidArrival(t *testing.T) {
	r, d, p := autopilotRequestFixture()
	armAutopilotDemand(r, p)
	sample, ok := d.finish(499, false)
	if !ok || sample.Reason != "client_departure" || sample.CapacityShed {
		t.Fatalf("valid departure lost or treated as capacity: %+v, recorded=%v", sample, ok)
	}
}

func TestAutopilotDemandCompactProfileWorksWithoutAnalyticsSink(t *testing.T) {
	r, d, _ := autopilotRequestFixture()
	srv := &Server{}
	rp := srv.newRequestProfile(r, "model-build", "model", true)
	if rp == nil || !rp.CompactOnly || d.profile != rp {
		t.Fatal("enabled demand observation needs a compact completion source")
	}
}

func TestAutopilotDemandDisabledLeavesExistingProfilerBehavior(t *testing.T) {
	srv := &Server{}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	got, d := srv.beginAutopilotDemand(r, time.Now())
	if got != r || d != nil || autopilotDemandFromContext(got.Context()) != nil {
		t.Fatal("disabled controller created demand state")
	}
	if rp := srv.newRequestProfile(r, "m", "m", false); rp != nil {
		t.Fatal("disabled controller enabled profiling")
	}
}
