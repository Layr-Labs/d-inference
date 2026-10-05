package promptcontract_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// A negotiated retry of a failing member keeps the already acknowledged healthy
// member ready while the retry is in flight.
func TestPreloadContinuityKeepsHealthyContractReadyDuringRetry(t *testing.T) {
	healthy, broken := strings.Repeat("a", 64), strings.Repeat("b", 64)
	release := make(chan struct{})
	entered := make(chan struct{}, 4)
	var preloads atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/ready":
			_ = json.NewEncoder(w).Encode(sidecar.ReadinessStatus{Status: "ok", Ready: true})
		case "/v1/preload", "/v2/preload":
			var request struct {
				IDs []string `json:"prompt_contract_ids"`
			}
			_ = json.NewDecoder(r.Body).Decode(&request)
			if preloads.Add(1) >= 2 {
				entered <- struct{}{}
				<-release // a slow retry of the same set (e.g. the broken member timing out)
			}
			report := readinessReport(request.IDs, broken)
			report.ContinuityVersion = 1
			_ = json.NewEncoder(w).Encode(report)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(func() { _ = server.Close() })
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	f := &readinessControllerFixture{t: t}
	f.provisioner = catalog.New()
	f.supervisor = &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	clock := time.Duration(0)
	controller, err := preload.New(f.provisioner, f.supervisor, client, preload.PreloadControllerConfig{
		FailureBackoffMin: 10 * time.Millisecond, FailureBackoffMax: 20 * time.Millisecond,
		PolicyNow: func() time.Duration { return clock },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	f.controller = controller
	f.verified(healthy, broken)

	controller.Reconcile(context.Background())
	if !controller.ReadyFor(healthy) || controller.ReadyFor(broken) {
		t.Fatalf("setup: expected healthy admitted and broken refused, status=%+v", controller.Status())
	}
	clock += time.Second // deterministic policy clock, past the failure backoff
	done := make(chan struct{})
	go func() { controller.Reconcile(context.Background()); close(done) }()
	select {
	case <-entered:
	case <-time.After(5 * time.Second):
		t.Fatal("retry preload never started")
	}
	healthyDuringRetry := controller.ReadyFor(healthy)
	close(release)
	<-done
	t.Logf("preloads=%d healthy admitted during retry=%v, after retry=%v", preloads.Load(), healthyDuringRetry, controller.ReadyFor(healthy))
	if !healthyDuringRetry {
		t.Error("a retry for a failing member closed the already-acknowledged healthy contract for the whole retry")
	}
}
