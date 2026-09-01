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
				map[string]struct{}{}, 0, nil, nil, reserver)
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
