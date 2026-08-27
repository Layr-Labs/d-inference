package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestApplyOutcomeDimensions(t *testing.T) {
	success := &store.InferenceRouteOutcome{FinalStatus: finalStatusSuccess, CostMicroUSD: 12}
	applyOutcomeDimensions(success)
	if success.ClientOutcome != "completed" || success.ProviderOutcome != "completed" || success.BillingOutcome != "charged" || !success.ResponseCommitted {
		t.Fatalf("success dimensions = %+v", success)
	}

	zero := &store.InferenceRouteOutcome{FinalStatus: finalStatusSuccess}
	applyOutcomeDimensions(zero)
	if zero.BillingOutcome != "zero_cost" {
		t.Fatalf("zero-cost billing = %q", zero.BillingOutcome)
	}

	partial := &store.InferenceRouteOutcome{
		FinalStatus: finalStatusPartialSuccess,
		ErrorClass:  errorClassClientGoneAfterCommitCompleted,
	}
	applyOutcomeDimensions(partial)
	if partial.ClientOutcome != "cancelled_after_commit" || partial.ProviderOutcome != "completed" || !partial.ResponseCommitted {
		t.Fatalf("partial dimensions = %+v", partial)
	}
}

func TestApplyCacheUsageTelemetry(t *testing.T) {
	out := &store.InferenceRouteOutcome{}
	applyCacheUsageTelemetry(out, protocol.UsageInfo{})
	if out.CacheOutcome != "" {
		t.Fatal("empty usage must not stamp cache outcome")
	}
	applyCacheUsageTelemetry(out, protocol.UsageInfo{
		CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 64, PrefillTokensSaved: 48, CacheStageMs: 3,
	})
	if out.CacheOutcome != "hit" || out.CachedTokens != 64 || out.CacheStageMs != 3 {
		t.Fatalf("cache usage = %+v", out)
	}
}

func TestCapacitySamplerRateLimit(t *testing.T) {
	c := newCapacitySampler()
	c.interval = time.Hour
	now := time.Now()
	if !c.shouldSample("p1", now) {
		t.Fatal("first sample must be allowed")
	}
	if c.shouldSample("p1", now.Add(time.Minute)) {
		t.Fatal("second sample inside the interval must be denied")
	}
	if !c.shouldSample("p2", now) {
		t.Fatal("a different provider must be sampled independently")
	}
	if !c.shouldSample("p1", now.Add(2*time.Hour)) {
		t.Fatal("sample after the interval must be allowed")
	}
}

func TestRouteCandidatesFromDecision(t *testing.T) {
	got := routeCandidatesFromDecision("req-1", 2, []registry.RouteCandidateSnapshot{
		{ProviderID: "p1", Rank: 0, Selected: true, Eligible: true, CostMs: 10, ChipFamily: "M4"},
		{ProviderID: "", Rank: 1},
	})
	if len(got) != 1 || got[0].RequestID != "req-1" || got[0].Attempt != 2 || got[0].ProviderID != "p1" {
		t.Fatalf("converted = %+v", got)
	}
}

func TestCandidateAndCapacityCSVHeaders(t *testing.T) {
	if err := writeCandidateCSV(httptest.NewRecorder(), nil); err != nil {
		t.Fatalf("writeCandidateCSV: %v", err)
	}
	if err := writeCapacitySampleCSV(httptest.NewRecorder(), nil); err != nil {
		t.Fatalf("writeCapacitySampleCSV: %v", err)
	}
	if len(candidateCSVHeader) == 0 || len(capacitySampleCSVHeader) == 0 {
		t.Fatal("csv headers empty")
	}
}

func TestTerminalSourceAndBillingHelpers(t *testing.T) {
	if got := terminalSourceFor(finalStatusSuccess, ""); got != "provider" {
		t.Fatalf("success source = %q", got)
	}
	if got := terminalSourceFor(finalStatusPartialSuccess, errorClassClientGoneAfterCommitCompleted); got != "client" {
		t.Fatalf("client-gone source = %q", got)
	}
	if got := terminalSourceFor(finalStatusTimeout, "first_chunk_timeout"); got != "coordinator_timeout" {
		t.Fatalf("timeout source = %q", got)
	}
	out := &store.InferenceRouteOutcome{}
	applyBillingSettlement(out, 100, 80, 0, 20)
	if out.ReservedMicroUSD != 100 || out.SettledMicroUSD != 80 || out.RefundMicroUSD != 20 {
		t.Fatalf("billing = %+v", out)
	}
	if coarseRegion(&store.ProviderLocation{RegionCode: "CA", CountryCode: "US"}) != "CA" {
		t.Fatal("coarse region should prefer region code")
	}
}

func TestAdminCandidatesAndCapacitySampleEndpoints(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{AdminKey: "test-key"}, logger)
	if err := st.RecordInferenceRouteCandidates([]store.InferenceRouteCandidateRecord{{
		RequestID: "req-admin", Attempt: 0, ProviderID: "p1", Rank: 0, Selected: true, Eligible: true, CostMs: 900,
	}}); err != nil {
		t.Fatal(err)
	}
	if err := st.RecordProviderCapacitySample(&store.ProviderCapacitySample{
		ProviderID: "p1", ObservedDecodeTPS: 33, MemoryGB: 64,
	}); err != nil {
		t.Fatal(err)
	}

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	req, err := http.NewRequest(http.MethodGet, ts.URL+"/v1/admin/candidates?since=2006-01-02T15:04:05Z", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("candidates status = %d", resp.StatusCode)
	}
	var body struct {
		Count int `json:"count"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Count != 1 {
		t.Fatalf("candidates count = %d, want 1", body.Count)
	}

	req, err = http.NewRequest(http.MethodGet, ts.URL+"/v1/admin/capacity-samples/export?format=csv&since=2006-01-02T15:04:05Z", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("capacity export status = %d", resp.StatusCode)
	}
}
