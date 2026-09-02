package api

// Routing-scan concurrency limit tests (2026-09-01 congestion collapse).
//
// Server.routingScanSem bounds how many provider-selection scans may run
// concurrently: excess dispatch goroutines park on the channel instead of
// piling CPU-bound fleet scans onto saturated cores, and one that cannot
// acquire within its remaining first-content budget sheds as a
// capacity-shaped retryable 429 (errRoutingScanSaturated / reason
// routing_saturated) — never a 5xx, never another scan.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestRoutingScanSemaphore_BoundsConcurrentScans launches N+2 dispatches
// against a capacity-N semaphore through the REAL funnel
// (dispatchWithReserver, the one seam every reserver flows through) and
// asserts that at most N reservers ever run simultaneously — and that all
// N+2 complete (waiters acquire freed slots; no deadlock).
func TestRoutingScanSemaphore_BoundsConcurrentScans(t *testing.T) {
	srv, _ := testServer(t)
	const capacity = 2
	const workers = capacity + 2
	srv.SetRoutingConcurrency(capacity)

	var inside, peak atomic.Int32
	reserver := func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
		cur := inside.Add(1)
		for {
			p := peak.Load()
			if cur <= p || peak.CompareAndSwap(p, cur) {
				break
			}
		}
		time.Sleep(80 * time.Millisecond) // hold the slot long enough to overlap
		inside.Add(-1)
		return nil, registry.RoutingDecision{}, nil
	}

	var wg sync.WaitGroup
	errs := make([]string, workers)
	codes := make([]int, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
			_, _, _, _, lastErr, lastErrCode := srv.dispatchWithReserver(
				r, "sem-model", "sem-model", []byte(`{"model":"sem-model"}`),
				"test-key", nil, 0, 0, 5*time.Second, 64,
				registry.TokenAdmission{}, false, registry.RequestTraits{},
				nil, false, selfRoutePolicy{}, nil, false, registry.CachePlan{},
				map[string]struct{}{}, 0, nil, nil, true, reserver)
			errs[i] = lastErr
			codes[i] = lastErrCode
		}(i)
	}
	wg.Wait()

	if got := peak.Load(); got > capacity {
		t.Fatalf("peak concurrent scans = %d, want <= %d", got, capacity)
	}
	// Every worker got a slot within its 5s budget and ran the reserver: the
	// nil-provider outcome is the ordinary "no provider available" 503, never
	// the saturation shed.
	for i := 0; i < workers; i++ {
		if errs[i] != "no provider available" || codes[i] != http.StatusServiceUnavailable {
			t.Errorf("worker %d = (%q, %d), want (no provider available, 503)", i, errs[i], codes[i])
		}
	}
}

// TestRoutingScanSemaphore_AcquireTimeoutShedsCapacityShaped429 fully
// occupies the semaphore and drives the real dispatch loop
// (dispatchState.run) with a short remaining first-content budget. The
// request must shed as the capacity-shaped retryable 429 WITHOUT any scan: a
// server with zero providers would answer "no provider available" → 503 if a
// scan ran, so the 429 + routing_saturated verdict proves the shed happened
// at the admission gate.
func TestRoutingScanSemaphore_AcquireTimeoutShedsCapacityShaped429(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRoutingConcurrency(2)
	// Occupy both slots for the whole test.
	srv.routingScanSem <- struct{}{}
	srv.routingScanSem <- struct{}{}
	defer func() { <-srv.routingScanSem; <-srv.routingScanSem }()

	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	deadline := 120 * time.Millisecond
	d := &dispatchState{
		s:                     srv,
		w:                     w,
		r:                     r,
		model:                 "saturated-model",
		publicModel:           "saturated-model",
		rawBody:               []byte(`{"model":"saturated-model"}`),
		consumerKey:           "test-key",
		estimatedPromptTokens: 6,
		requestedMaxTokens:    64,
		timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
		deadline:              deadline,
		speculativeAt:         deadline / 2,
		refundReservation:     func() {},
		excludeProviders:      map[string]struct{}{},
	}

	start := time.Now()
	d.run()
	elapsed := time.Since(start)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (capacity-shaped shed, NOT the 503 a scan would produce); body=%s",
			w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "rate_limit_exceeded") {
		t.Errorf("body missing rate_limit_exceeded code; body=%s", w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After header on the 429")
	}
	if !d.unservable || d.unservableReason != rejectionReasonRoutingSaturated {
		t.Errorf("verdict = (unservable=%v, reason=%q), want (true, %q)",
			d.unservable, d.unservableReason, rejectionReasonRoutingSaturated)
	}
	if d.attempt != 0 {
		t.Errorf("attempts = %d, want the shed to terminate the ladder at attempt 0", d.attempt+1)
	}
	// The goroutine parked for (about) the remaining budget before shedding,
	// and never longer.
	if elapsed < 80*time.Millisecond || elapsed > 3*time.Second {
		t.Errorf("shed after %s, want ~the 120ms remaining budget", elapsed)
	}
}

// TestRoutingScanSemaphore_ClientGoneTakesClientGonePath cancels the caller
// while it is parked for a scan slot. The dispatch loop must take the
// EXISTING client-gone terminal — refund, no response bytes, no Retry-After —
// and never the routing_saturated 429 or a rejection-ledger row: the client
// is not retrying, so the ledger must not count a shed that never happened.
func TestRoutingScanSemaphore_ClientGoneTakesClientGonePath(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRoutingConcurrency(2)
	srv.routingScanSem <- struct{}{}
	srv.routingScanSem <- struct{}{}
	defer func() { <-srv.routingScanSem; <-srv.routingScanSem }()

	ctx, cancel := context.WithCancel(context.Background())
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}")).WithContext(ctx)
	refunds := 0
	deadline := 5 * time.Second // far beyond the cancel point: the timeout arm must not win
	d := &dispatchState{
		s:                     srv,
		w:                     w,
		r:                     r,
		model:                 "client-gone-model",
		publicModel:           "client-gone-model",
		rawBody:               []byte(`{"model":"client-gone-model"}`),
		consumerKey:           "test-key",
		estimatedPromptTokens: 6,
		requestedMaxTokens:    64,
		timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
		deadline:              deadline,
		speculativeAt:         deadline / 2,
		refundReservation:     func() { refunds++ },
		excludeProviders:      map[string]struct{}{},
	}

	go func() {
		time.Sleep(40 * time.Millisecond)
		cancel()
	}()
	d.run()

	if w.Body.Len() != 0 {
		t.Fatalf("client-gone wrote a response body: %s", w.Body.String())
	}
	if w.Header().Get("Retry-After") != "" {
		t.Error("client-gone must not carry a Retry-After header")
	}
	if d.unservable {
		t.Errorf("client-gone latched unservable(%q) — that is the saturation verdict", d.unservableReason)
	}
	if refunds != 1 {
		t.Errorf("reservation refunds = %d, want exactly 1", refunds)
	}
	if got := len(st.RejectionRecordsSince(time.Time{})); got != 0 {
		t.Errorf("rejection-ledger rows = %d, want 0 for a client-gone", got)
	}
}

// TestPreflightAdmission_ScanSaturationStormSheds429 proves the admission
// preflight's fleet walks run behind the SAME semaphore as dispatch scans:
// with every slot held, a storm of N+K concurrent HTTP admissions performs
// ZERO walks (each sheds the capacity-shaped routing_saturated 429 after its
// short slice — a scan would instead have found the healthy provider and
// served 200), and once the slots free the next admission walks, dispatches,
// and streams normally.
func TestPreflightAdmission_ScanSaturationStormSheds429(t *testing.T) {
	reg, _, srv, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	const model = "preflight-sat-model"
	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name:      "healthy",
		Version:   "0.7.0",
		DecodeTPS: 100,
		Models:    []failoverModelSpec{{ID: model}},
		Script:    fullServeScript(model),
	})

	srv.SetRoutingConcurrency(2)
	srv.routingScanSem <- struct{}{}
	srv.routingScanSem <- struct{}{}

	const storm = 4 // N+K admissions against N=2 fully-held slots
	var wg sync.WaitGroup
	var shed429 atomic.Int32
	for i := 0; i < storm; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
			if err != nil {
				t.Errorf("storm request: %v", err)
				return
			}
			if status != http.StatusTooManyRequests {
				t.Errorf("storm status = %d, want 429; body=%s", status, body)
				return
			}
			if !strings.Contains(body, "rate_limit_exceeded") {
				t.Errorf("storm body missing rate_limit_exceeded: %s", body)
				return
			}
			shed429.Add(1)
		}()
	}
	wg.Wait()
	if got := fp.dispatchCount(); got != 0 {
		t.Fatalf("provider dispatches during saturation = %d, want 0 (zero fleet walks)", got)
	}
	if got := shed429.Load(); got != storm {
		t.Fatalf("saturation sheds = %d, want %d", got, storm)
	}

	// Slots freed: the same admission now walks the fleet and serves.
	<-srv.routingScanSem
	<-srv.routingScanSem
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("post-release request: %v", err)
	}
	if status != http.StatusOK || !strings.Contains(body, markerFor("healthy")) {
		t.Fatalf("post-release = %d (%s), want 200 with the provider's content", status, body)
	}
	if fp.dispatchCount() == 0 {
		t.Fatal("post-release request never reached the provider")
	}
}

// TestRoutingScanSemaphore_PlanStepBypassesGate proves a retained-plan
// reservation (ReserveNextFromPlan — bounded revalidation of at most the
// plan's entries, no fleet scan) proceeds even when every scan slot is held:
// the cheap retry path exists precisely to avoid rescans, so the scan gate
// must never starve it. The identical reserver declared as a full scan blocks
// (sheds) under the same held semaphore.
func TestRoutingScanSemaphore_PlanStepBypassesGate(t *testing.T) {
	srv, _ := testServer(t)
	srv.SetRoutingConcurrency(2)
	srv.routingScanSem <- struct{}{}
	srv.routingScanSem <- struct{}{}
	defer func() { <-srv.routingScanSem; <-srv.routingScanSem }()

	reserverRan := false
	reserver := func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
		reserverRan = true
		return nil, registry.RoutingDecision{}, nil
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))

	// Plan step (fullScan=false): must run the reserver despite zero free slots.
	_, _, _, _, lastErr, _ := srv.dispatchWithReserver(
		r, "plan-model", "plan-model", []byte(`{"model":"plan-model"}`),
		"test-key", nil, 0, 0, 200*time.Millisecond, 64,
		registry.TokenAdmission{}, false, registry.RequestTraits{},
		nil, false, selfRoutePolicy{}, nil, false, registry.CachePlan{},
		map[string]struct{}{}, 1, nil, nil, false, reserver)
	if !reserverRan {
		t.Fatal("plan-step reserver never ran — the bypass is broken")
	}
	if lastErr != "no provider available" {
		t.Fatalf("plan step = %q, want the reserver's ordinary no-provider outcome", lastErr)
	}

	// The same reserver behind the gate (fullScan=true) sheds without running.
	reserverRan = false
	_, _, _, _, lastErr, lastErrCode := srv.dispatchWithReserver(
		r, "plan-model", "plan-model", []byte(`{"model":"plan-model"}`),
		"test-key", nil, 0, 0, 100*time.Millisecond, 64,
		registry.TokenAdmission{}, false, registry.RequestTraits{},
		nil, false, selfRoutePolicy{}, nil, false, registry.CachePlan{},
		map[string]struct{}{}, 1, nil, nil, true, reserver)
	if reserverRan {
		t.Fatal("gated reserver ran with every slot held")
	}
	if lastErr != errRoutingScanSaturated || lastErrCode != http.StatusTooManyRequests {
		t.Fatalf("gated = (%q, %d), want (%q, 429)", lastErr, lastErrCode, errRoutingScanSaturated)
	}
}
