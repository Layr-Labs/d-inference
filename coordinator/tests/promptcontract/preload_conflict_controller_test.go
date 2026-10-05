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

// This control also compiles on the original D64 controller: HTTP 409 did not
// accept a Rust replacement and must not become a failed-tokenizer/backoff event.
func TestPreloadControllerConflictDoesNotBecomeFailedRuntimeLoad(t *testing.T) {
	id := strings.Repeat("a", 64)
	ready := sidecar.PreloadReport{ContinuityVersion: 1, Status: "ready", Ready: true, Requested: 1, Warm: 1,
		Results: []sidecar.PreloadResult{{PromptContractID: id, Status: "warm"}}}
	// start answers the first preload with HTTP 409 and each later one with
	// report's choice for that call.
	start := func(config preload.PreloadControllerConfig, report func(call int64) sidecar.PreloadReport) (*preload.PreloadController, *atomic.Int64) {
		calls := new(atomic.Int64)
		server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			call := calls.Add(1)
			if call == 1 {
				http.Error(w, "preload already in progress", http.StatusConflict)
				return
			}
			_ = json.NewEncoder(w).Encode(report(call))
		}))
		t.Cleanup(func() { _ = server.Close() })
		client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 1})
		t.Cleanup(client.Close)
		provisioner := catalog.New()
		provisioner.Replace([]catalog.Status{{ModelID: "fixture", ArtifactReady: true, PromptContractID: id,
			ModelAggregateSHA256: strings.Repeat("b", 64)}})
		supervisor := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
		controller, err := preload.New(provisioner, supervisor, client, config)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(controller.Close)
		return controller, calls
	}
	controller, calls := start(preload.PreloadControllerConfig{}, func(int64) sidecar.PreloadReport { return ready })
	controller.Reconcile(context.Background())
	if controller.Status().Failures != 0 || controller.Status().Ready {
		t.Fatal("409 changed failed-load accounting, backoff or publication")
	}
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(id) || controller.Status().Runs != 1 || controller.Status().Failures != 0 || calls.Load() != 2 {
		t.Fatal("unaccepted conflict prevented immediate independent recovery")
	}

	// A backoff started by the 409 has no effect on the retry above. It shows in
	// the next real failure of the same set, whose retry then waits twice the
	// minimum instead of exactly the minimum.
	now := new(atomic.Int64)
	controller, calls = start(preload.PreloadControllerConfig{
		FailureBackoffMin: time.Second, FailureBackoffMax: time.Minute,
		PolicyNow: func() time.Duration { return time.Duration(now.Load()) },
	}, func(call int64) sidecar.PreloadReport {
		if call == 2 {
			return sidecar.PreloadReport{ContinuityVersion: 1, Status: "degraded", Requested: 1, Failed: 1,
				Results: []sidecar.PreloadResult{{PromptContractID: id, Status: "failed"}}}
		}
		return ready
	})
	controller.Reconcile(context.Background()) // The 409.
	controller.Reconcile(context.Background()) // The first real failure.
	now.Store(int64(time.Second - 1))
	controller.Reconcile(context.Background())
	waiting := calls.Load()
	now.Store(int64(time.Second))
	controller.Reconcile(context.Background())
	if waiting != 2 || calls.Load() != 3 || !controller.ReadyFor(id) || controller.Status().Failures != 1 {
		t.Fatal("409 changed failed-load accounting, backoff or publication")
	}
}
