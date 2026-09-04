package api

// Rejection-ledger counterfactual (T12-02): the servability walk that
// recordRejection runs on the telemetry sink worker for callers that did not
// seed it (routing_saturated, model_shed, the dispatch-exhausted tail) takes
// the registry read lock and per-provider locks — the locks the request-path
// routing scans contend for. It now runs only when a routing-scan slot is
// free (skipped rows carry candidate_count = -1), and the exhausted tail
// seeds its row from the ladder's last routing decision instead.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// holdRoutingScanSlots saturates the routing-scan semaphore; the returned
// func releases it.
func holdRoutingScanSlots(srv *Server) func() {
	srv.SetRoutingConcurrency(2)
	srv.routingScanSem <- struct{}{}
	srv.routingScanSem <- struct{}{}
	return func() { <-srv.routingScanSem; <-srv.routingScanSem }
}

// latestRejection returns the most recently recorded rejection row
// (RejectionRecordsSince is newest-first).
func latestRejection(t *testing.T, st store.Store) store.RejectionRecord {
	t.Helper()
	recs := st.RejectionRecordsSince(time.Time{})
	if len(recs) == 0 {
		t.Fatal("no rejection rows")
	}
	return recs[0]
}

func unseededRejection(r *http.Request, stage, reason, model string) rejectionInfo {
	return rejectionInfo{
		r:                     r,
		stage:                 stage,
		reasonCode:            reason,
		httpStatus:            http.StatusTooManyRequests,
		requestedModel:        model,
		resolvedModel:         model,
		estimatedPromptTokens: 10,
		requestedMaxTokens:    64,
		retryAfterMs:          2000,
	}
}

// TestRecordRejectionCounterfactualUnderScanSaturation: with a routable
// provider registered (so a walk WOULD find a candidate) and the scan
// semaphore saturated, the sink records the row without walking the fleet
// and marks it candidate_count = -1 / could_have_served = false. With the
// semaphore free the walk runs exactly as before (semantics preserved).
func TestRecordRejectionCounterfactualUnderScanSaturation(t *testing.T) {
	srv, reg, st, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "counterfactual-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")
	makeProviderRoutable(reg)

	release := holdRoutingScanSlots(srv)
	walks := reg.QuickCapacityWalks()
	for _, stage := range []struct{ stage, reason string }{
		{"preflight_capacity", rejectionReasonRoutingSaturated},
		{"model_shed", "model_shed"},
	} {
		srv.recordRejection(unseededRejection(modelShedRequest(), stage.stage, stage.reason, model))
	}
	waitForRejectionCount(t, srv, 2)
	for _, rec := range st.RejectionRecordsSince(time.Time{}) {
		if rec.CandidateCount != rejectionCounterfactualSkipped || rec.CouldHaveServed {
			t.Fatalf("%s row under saturation = (candidate_count=%d, could_have_served=%v), want (-1, false)", rec.ReasonCode, rec.CandidateCount, rec.CouldHaveServed)
		}
	}
	if got := reg.QuickCapacityWalks(); got != walks {
		t.Fatalf("fleet walks advanced from %d to %d while the scans were saturated", walks, got)
	}
	release()

	srv.recordRejection(unseededRejection(modelShedRequest(), "model_shed", "model_shed", model))
	waitForRejectionCount(t, srv, 3)
	rec := latestRejection(t, st)
	if rec.CandidateCount < 1 || !rec.CouldHaveServed {
		t.Fatalf("row with scan headroom = (candidate_count=%d, could_have_served=%v), want the walk's (>=1, true)", rec.CandidateCount, rec.CouldHaveServed)
	}
	if got := reg.QuickCapacityWalks(); got != walks+1 {
		t.Fatalf("fleet walks = %d, want %d (exactly one walk with headroom)", got, walks+1)
	}
	if got := len(srv.routingScanSem); got != 0 {
		t.Fatalf("scan slot leaked by the sink walk: %d held", got)
	}
}

// TestModelShedOverHTTPUnderScanSaturationDoesNotWalk drives the real
// model_shed 429 through the handler with the semaphore saturated.
func TestModelShedOverHTTPUnderScanSaturationDoesNotWalk(t *testing.T) {
	srv, reg, st, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "shed-http-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "")
	makeProviderRoutable(reg)
	srv.SetRejectModels(map[string]bool{model: true})

	release := holdRoutingScanSlots(srv)
	defer release()
	walks := reg.QuickCapacityWalks()
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"max_tokens":16}`
	status, respBody, err := postChat(ctx, ts.URL, "test-key", body)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	if status != http.StatusTooManyRequests || !strings.Contains(respBody, "rate-limited") {
		t.Fatalf("status = %d body = %s, want the model_shed 429", status, respBody)
	}
	waitForRejectionCount(t, srv, 1)
	rec := latestRejection(t, st)
	if rec.ReasonCode != "model_shed" || rec.CandidateCount != rejectionCounterfactualSkipped || rec.CouldHaveServed {
		t.Fatalf("row = (reason=%s, candidate_count=%d, could_have_served=%v), want (model_shed, -1, false)", rec.ReasonCode, rec.CandidateCount, rec.CouldHaveServed)
	}
	if got := reg.QuickCapacityWalks(); got != walks {
		t.Fatalf("fleet walks advanced from %d to %d for a model_shed under saturation", walks, got)
	}
}

// TestExhaustedRejectionInfoUsesLastDecision pins the exhausted tail's
// seeding: terminal verdicts are not-servable, otherwise the ladder's last
// decision is the counterfactual, and a ladder without a decision leaves it
// to the sink.
func TestExhaustedRejectionInfoUsesLastDecision(t *testing.T) {
	srv, _ := testServer(t)
	d := &dispatchState{s: srv, r: modelShedRequest(), model: "m", publicModel: "m"}

	info := d.exhaustedRejectionInfo("all_capacity", http.StatusTooManyRequests, 2000, false)
	if info.servabilityComputed {
		t.Fatal("no decision recorded: servability must be left to the sink")
	}

	d.recordRoutingDecisionFor(nil, nil, "req", 0, registry.RoutingDecision{CandidateCount: 7, CapacityRejections: 3, ModelTooLargeRejections: 1, VisionRejections: 2, BestTTFTMs: 42}, "no provider available", "")
	// A later zero-count decision (retry scan against the exclusion set, or
	// the terminal no-provider scan) must not overwrite the informative one.
	d.recordRoutingDecisionFor(nil, nil, "req", 1, registry.RoutingDecision{}, "no provider available", "")
	info = d.exhaustedRejectionInfo("all_capacity", http.StatusTooManyRequests, 2000, false)
	if !info.servabilityComputed || info.candidateCount != 7 || info.capacityRejections != 3 || info.modelTooLargeRejections != 1 || info.visionRejections != 2 || info.bestTTFTMs != 42 {
		t.Fatalf("info from last decision = %+v", info)
	}
	if info.stage != "dispatch" || info.reasonCode != "all_capacity" || info.retryAfterMs != 2000 {
		t.Fatalf("info identity = (%s, %s, %d)", info.stage, info.reasonCode, info.retryAfterMs)
	}

	info = d.exhaustedRejectionInfo(errorReasonDeadlineUnreachable, http.StatusServiceUnavailable, 0, true)
	if !info.servabilityComputed || info.candidateCount != 0 {
		t.Fatalf("terminal verdict = %+v, want servabilityComputed with candidate_count 0", info)
	}
}

// TestExhaustedDispatchRejectionCarriesLastDecision: every provider
// capacity-rejects, the ladder exhausts with a 429, and the rejection row's
// counterfactual equals the ladder's last informative scan (the first
// attempt's inference_routes row: 2 candidates; the retry and terminal
// scans report zero counts) — could_have_served stays true, as the sink's
// walk would have answered, and no walk runs after the response.
func TestExhaustedDispatchRejectionCarriesLastDecision(t *testing.T) {
	t.Setenv("EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD", "100")
	reg, st, srv, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	const model = "exhausted-ladder-model"
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonCapacityBusy, http.StatusTooManyRequests)
	}
	for _, name := range []string{"provider-a", "provider-b"} {
		startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: name, Version: "0.8.10", DecodeTPS: 200,
			Models: []failoverModelSpec{{ID: model}}, Script: script,
		})
	}

	status, body, err := postChat(ctx, ts.URL, "test-key", `{"model":"`+model+`","messages":[{"role":"user","content":"hi"}],"max_tokens":16}`)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	walksAfterResponse := reg.QuickCapacityWalks()
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d body = %s, want the exhausted-ladder 429", status, body)
	}
	waitForRejectionCount(t, srv, 1)
	rec := latestRejection(t, st)
	if rec.Stage != "dispatch" {
		t.Fatalf("stage = %q, want dispatch", rec.Stage)
	}
	var informative *store.InferenceRouteRecord
	attempts := 0
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		attempts++
		if r.CandidateCount > 0 && (informative == nil || r.Attempt > informative.Attempt) {
			rr := r
			informative = &rr
		}
	}
	if informative == nil || attempts < 2 {
		t.Fatalf("ladder recorded %d attempts, informative scan = %v", attempts, informative)
	}
	if rec.CandidateCount != informative.CandidateCount || rec.CapacityRejections != informative.CapacityRejections {
		t.Fatalf("rejection counterfactual = (%d, %d), want the ladder's last informative scan (%d, %d)", rec.CandidateCount, rec.CapacityRejections, informative.CandidateCount, informative.CapacityRejections)
	}
	if rec.CandidateCount != 2 || !rec.CouldHaveServed {
		t.Fatalf("two providers advertised the model; row = (candidate_count=%d, could_have_served=%v), want (2, true)", rec.CandidateCount, rec.CouldHaveServed)
	}
	// The row was seeded, so the sink ran no walk after the response.
	if got := reg.QuickCapacityWalks(); got != walksAfterResponse {
		t.Fatalf("fleet walks advanced from %d to %d after the response — the sink re-walked", walksAfterResponse, got)
	}
}

// BenchmarkRejectionCounterfactualWalk measures the fleet walk a skipped
// rejection avoids: 1,300 registered providers, 10% advertising the model
// (the per-model index visits only those).
func BenchmarkRejectionCounterfactualWalk(b *testing.B) {
	reg := registry.New(quietLogger())
	const model = "bench-walk-model"
	for i := 0; i < 1300; i++ {
		m := fmt.Sprintf("other-model-%d", i%40)
		if i%10 == 0 {
			m = model
		}
		id := fmt.Sprintf("bench-provider-%d", i)
		reg.Register(id, nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: m, ModelType: "chat", Quantization: "4bit"}}})
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
	traits := registry.RequestTraits{}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		reg.QuickCapacityCheckWithTTFTForRequest(model, 500, 256, traits, false)
	}
}
