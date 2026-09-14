package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Routing-scan concurrency limit tests (2026-09-01 congestion collapse).
//
// Server.routingScanSem bounds how many provider-selection scans may run
// concurrently: excess dispatch goroutines park on the channel instead of
// piling CPU-bound fleet scans onto saturated cores, and one that cannot
// acquire within its remaining first-content budget sheds as a
// capacity-shaped retryable 429 (errRoutingScanSaturated / reason
// routing_saturated) — never a 5xx, never another scan.

// TestRoutingScanSemaphore_ClientGoneTakesClientGonePath cancels the caller
// while it is parked for a scan slot. The dispatch loop must take the
// EXISTING client-gone terminal — refund, no response bytes, no Retry-After —
// and never the routing_saturated 429 or a rejection-ledger row: the client
// is not retrying, so the ledger must not count a shed that never happened.
func TestRoutingScanSemaphore_ClientGoneTakesClientGonePath(t *testing.T) {
	srv, st := testServer(t)
	srv.SetRoutingConcurrency(2)
	if got := srv.inferenceDispatch().AcquireRoutingScanSlot(0, nil); got != dispatch.ScanSlotAcquired {
		t.Fatalf("fixture could not hold scan slot: %v", got)
	}
	if got := srv.inferenceDispatch().AcquireRoutingScanSlot(0, nil); got != dispatch.ScanSlotAcquired {
		t.Fatalf("fixture could not hold scan slot: %v", got)
	}
	defer func() {
		srv.inferenceDispatch().ReleaseRoutingScanSlot()
		srv.inferenceDispatch().ReleaseRoutingScanSlot()
	}()

	ctx, cancel := context.WithCancel(context.Background())
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}")).WithContext(ctx)
	refunds := 0
	deadline := 5 * time.Second // far beyond the cancel point: the timeout arm must not win
	request := dispatch.Request{
		Model:                 "client-gone-model",
		PublicModel:           "client-gone-model",
		RawBody:               []byte(`{"model":"client-gone-model"}`),
		ConsumerKey:           "test-key",
		EstimatedPromptTokens: 6,
		RequestedMaxTokens:    64,
		Timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
		Deadline:              deadline,
		SpeculativeAt:         deadline / 2,
		RefundReservation:     func() { refunds++ },
	}

	go func() {
		time.Sleep(40 * time.Millisecond)
		cancel()
	}()
	srv.inferenceDispatch().Run(w, r, request)

	if w.Body.Len() != 0 {
		t.Fatalf("client-gone wrote a response body: %s", w.Body.String())
	}
	if w.Header().Get("Retry-After") != "" {
		t.Error("client-gone must not carry a Retry-After header")
	}
	if w.Code == http.StatusTooManyRequests {
		t.Errorf("client-gone wrote saturation status %d", w.Code)
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
	if got := srv.inferenceDispatch().AcquireRoutingScanSlot(0, nil); got != dispatch.ScanSlotAcquired {
		t.Fatalf("fixture could not hold scan slot: %v", got)
	}
	if got := srv.inferenceDispatch().AcquireRoutingScanSlot(0, nil); got != dispatch.ScanSlotAcquired {
		t.Fatalf("fixture could not hold scan slot: %v", got)
	}

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
	srv.inferenceDispatch().ReleaseRoutingScanSlot()
	srv.inferenceDispatch().ReleaseRoutingScanSlot()
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
