package inference_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	dispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
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
			_, _, _, _, lastErr, lastErrCode := srv.NewDispatcher().Dispatch(
				r, "sem-model", "sem-model", []byte(`{"model":"sem-model"}`),
				"test-key", nil, 0, 0, 5*time.Second, 64,
				registry.TokenAdmission{}, false, registry.RequestTraits{},
				nil, false, dispatch.Scope{}, nil, false, registry.CachePlan{}, dispatch.NewExclusions(), 0, nil, "", nil, nil, true, reserver)
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
	srv.scanGate.Acquire(0, nil)
	srv.scanGate.Acquire(0, nil)

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
	srv.scanGate.Release()
	srv.scanGate.Release()
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
	srv.scanGate.Acquire(0, nil)
	srv.scanGate.Acquire(0, nil)
	defer func() { srv.scanGate.Release(); srv.scanGate.Release() }()

	reserverRan := false
	reserver := func(pr *registry.PendingRequest, excludeIDs []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
		reserverRan = true
		return nil, registry.RoutingDecision{}, nil
	}
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))

	// Plan step (fullScan=false): must run the reserver despite zero free slots.
	_, _, _, _, lastErr, _ := srv.NewDispatcher().Dispatch(
		r, "plan-model", "plan-model", []byte(`{"model":"plan-model"}`),
		"test-key", nil, 0, 0, 200*time.Millisecond, 64,
		registry.TokenAdmission{}, false, registry.RequestTraits{},
		nil, false, dispatch.Scope{}, nil, false, registry.CachePlan{}, dispatch.NewExclusions(), 1, nil, "", nil, nil, false, reserver)
	if !reserverRan {
		t.Fatal("plan-step reserver never ran — the bypass is broken")
	}
	if lastErr != "no provider available" {
		t.Fatalf("plan step = %q, want the reserver's ordinary no-provider outcome", lastErr)
	}

	// The same reserver behind the gate (fullScan=true) sheds without running.
	reserverRan = false
	_, _, _, _, lastErr, lastErrCode := srv.NewDispatcher().Dispatch(
		r, "plan-model", "plan-model", []byte(`{"model":"plan-model"}`),
		"test-key", nil, 0, 0, 100*time.Millisecond, 64,
		registry.TokenAdmission{}, false, registry.RequestTraits{},
		nil, false, dispatch.Scope{}, nil, false, registry.CachePlan{}, dispatch.NewExclusions(), 1, nil, "", nil, nil, true, reserver)
	if reserverRan {
		t.Fatal("gated reserver ran with every slot held")
	}
	if lastErr !=
		dispatch.RoutingScanSaturated ||
		lastErrCode != http.StatusTooManyRequests {
		t.Fatalf("gated = (%q, %d), want (%q, 429)", lastErr, lastErrCode, dispatch.RoutingScanSaturated)
	}
}
