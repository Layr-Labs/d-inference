package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// withTestDD attaches a UDP DogStatsD collector to the server and returns it.
func withTestDD(t *testing.T, s *Server) *udpCollector {
	t.Helper()
	collector := newUDPCollector(t)
	dd := newTestDD(t, collector)
	s.SetDatadog(dd)
	t.Cleanup(func() {
		dd.Close()
		collector.Close()
	})
	return collector
}

func flushDD(t *testing.T, s *Server, collector *udpCollector) []string {
	t.Helper()
	if err := s.dd.Statsd.Flush(); err != nil {
		t.Fatalf("flush: %v", err)
	}
	return collector.drain()
}

// hasSeries reports whether some packet carries the metric (name:value|type
// prefix) AND the tag; the client prepends its global env/service tags, so
// the two are matched independently.
func hasSeries(packets []string, series, tag string) bool {
	for _, p := range packets {
		if strings.Contains(p, series) && strings.Contains(p, tag) {
			return true
		}
	}
	return false
}

// TestPlanSkipCountersEmitPerReason pins the wiring at dispatchFromPlanMachinery:
// every PlanSkip the registry computes reaches DogStatsD as one
// dispatch_plan.skip{reason} increment (the slice used to be discarded), and
// exhaustion emits the entries_consumed histogram.
func TestPlanSkipCountersEmitPerReason(t *testing.T) {
	s := newTestServerForDispatch(t)
	collector := withTestDD(t, s)
	const model = "plan-skip-metrics-model"
	for i := range 4 {
		planWiringProvider(t, s.registry, "ps"+string(rune('a'+i)), model, int64(i)*400)
	}
	plan := planWiringPlan(t, s.registry, model)
	if plan.Len() < 3 {
		t.Fatalf("plan retained %d entries, want >= 3", plan.Len())
	}
	// Entry 0 loses its session (stale_session); entry 1 goes offline
	// (gate_rejected); entry 2 is excluded by the caller (excluded).
	first, _ := plan.PeekNext()
	s.registry.Disconnect(first.ProviderID)
	// The plan order is ascending backlog: psa (winner), psb, psc, psd.
	gated := s.registry.GetProvider("psc")
	if gated == nil {
		t.Fatal("fixture: psc missing")
	}
	gated.Mu().Lock()
	gated.Status = registry.StatusOffline
	gated.Mu().Unlock()

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	d := &dispatchState{
		s:                 s,
		r:                 req,
		model:             model,
		publicModel:       model,
		rawBody:           []byte(`{"model":"` + model + `"}`),
		deadline:          5 * time.Second,
		speculativeAt:     2500 * time.Millisecond,
		timing:            &registry.RequestTiming{ReceivedAt: time.Now()},
		excludeProviders:  map[string]struct{}{"psd": {}},
		refundReservation: func() {},
		plan:              plan,
	}
	// Consume until the plan is exhausted and the single refresh is spent.
	for i := 0; i < plan.Len()+2; i++ {
		if _, _, _, _, _, tried := d.dispatchFromPlanMachinery(d.timing, d.excludeProviders, "", nil); !tried && d.planRefreshUsed {
			break
		}
	}
	packets := flushDD(t, s, collector)
	for _, reason := range []string{"stale_session", "gate_rejected", "excluded", "exhausted"} {
		if !hasSeries(packets, "dispatch_plan.skip:1|c|", "reason:"+reason) {
			t.Errorf("missing dispatch_plan.skip reason:%s; packets: %v", reason, packets)
		}
	}
	if !hasMetric(packets, "dispatch_plan.entries_consumed:3|h") {
		t.Errorf("missing entries_consumed histogram (3 entries consumed); packets: %v", packets)
	}
}

// TestReserveDecisionMetricsEmitRescans pins the per-reserve series: the
// rescan count is always emitted, the rescan cost only when a rescan happened.
func TestReserveDecisionMetricsEmitRescans(t *testing.T) {
	s, _ := testServer(t)
	collector := withTestDD(t, s)
	s.emitReserveDecisionMetrics("m", registry.RoutingDecision{})
	packets := flushDD(t, s, collector)
	if !hasSeries(packets, "routing.reserve_rescans:0|h|", "model:m") {
		t.Fatalf("missing zero rescans histogram; packets: %v", packets)
	}
	if hasMetric(packets, "routing.reserve_rescan_us") {
		t.Fatalf("rescan cost emitted without a rescan; packets: %v", packets)
	}
	s.emitReserveDecisionMetrics("m", registry.RoutingDecision{Rescans: 2, RescanUS: 1500})
	packets = flushDD(t, s, collector)
	if !hasSeries(packets, "routing.reserve_rescans:2|h|", "model:m") || !hasSeries(packets, "routing.reserve_rescan_us:1500|h|", "model:m") {
		t.Fatalf("missing rescan series; packets: %v", packets)
	}
}

// TestRegistryLockGaugesEmit pins the gauge-tick series: writer-wait gauges,
// the acquisition count, and the fleet-walk / shadow-rescan deltas.
func TestRegistryLockGaugesEmit(t *testing.T) {
	s, _ := testServer(t)
	collector := withTestDD(t, s)
	const model = "lock-gauge-model"
	makeRoutableProvider(t, s.registry, "lg1", model)
	s.registry.LockWaitSnapshot() // discard fixture acquisitions
	// One reservation = one fleet walk and one exclusive commit acquisition.
	pr := &registry.PendingRequest{RequestID: "lg-req", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 100}
	p, dec := s.registry.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("reserve failed: %+v", dec)
	}
	p.RemovePending(pr.RequestID)

	s.emitRegistryLockGauges()
	packets := flushDD(t, s, collector)
	for _, want := range []string{
		"registry.mu.writers_waiting:0|g",
		"registry.mu.lock_acquisitions:1|c",
		"registry.mu.lock_wait_ms:", // mean/p50/p99/max
		"stat:p99",
		"routing.fleet_walks:1|c",
		"routing.shadow_rescan:0|c",
	} {
		if !hasMetric(packets, want) {
			t.Errorf("missing %q; packets: %v", want, packets)
		}
	}
	// Deltas: a second tick with no activity reports zero walks and zero
	// acquisitions (the window was reset).
	s.emitRegistryLockGauges()
	packets = flushDD(t, s, collector)
	if !hasMetric(packets, "routing.fleet_walks:0|c") || !hasMetric(packets, "registry.mu.lock_acquisitions:0|c") {
		t.Fatalf("second tick must report deltas of zero; packets: %v", packets)
	}
}

// TestHedgeGovernorSnapshotCounter pins the governor's allow-path counter:
// every governor decision takes a fleet snapshot and is counted (the
// suppressed verdict already had a series; the allow path had none).
func TestHedgeGovernorSnapshotCounter(t *testing.T) {
	d, _ := firstTokenWaitState(t, 0, 500*time.Millisecond)
	collector := withTestDD(t, d.s)
	d.tryAcquireBackupHedge("first-token-provider")
	packets := flushDD(t, d.s, collector)
	if !hasSeries(packets, "routing.hedge_governor_snapshot:1|c|", "model:first-token-deadline-model") {
		t.Fatalf("missing hedge governor snapshot counter; packets: %v", packets)
	}
}

// TestFleetSampleCarriesReserveLockWaitP95 pins the previously-dead
// fleet_snapshots.reserve_lock_wait_p95_us column: the coordinator row
// carries the writer-wait p95 of the current window.
func TestFleetSampleCarriesReserveLockWaitP95(t *testing.T) {
	srv, st := testServer(t)
	reg := srv.registry
	reg.LockWaitSnapshot()
	// A few exclusive acquisitions so the window is non-empty; the row must
	// carry exactly the instrument's current-window p95 (peek, not reset).
	for range 5 {
		reg.RecordCapacityReject("fp1", "fleet-p95-model")
	}
	want := reg.LockWaitPeek()
	if want.Count != 5 {
		t.Fatalf("peek Count = %d, want 5", want.Count)
	}
	srv.sampleFleetOnce(time.Now())
	rows := st.FleetSnapshotsSince(time.Time{})
	found := false
	for _, row := range rows {
		if row.ProviderID == "coordinator" {
			found = true
			if row.ReserveLockWaitP95US != want.P95US {
				t.Fatalf("reserve_lock_wait_p95_us = %d, want the window p95 %d", row.ReserveLockWaitP95US, want.P95US)
			}
		}
	}
	if !found {
		t.Fatal("no coordinator row sampled")
	}
	if after := reg.LockWaitPeek(); after.Count != 5 {
		t.Fatalf("sampler must not reset the window: Count = %d, want 5", after.Count)
	}
}
