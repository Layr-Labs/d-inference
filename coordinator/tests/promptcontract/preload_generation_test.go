package promptcontract_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestPreloadControllerDiscardsChangedGenerationsDuringPreload(t *testing.T) {
	for _, changed := range []string{"catalog", "child"} {
		t.Run(changed, func(t *testing.T) {
			contract := strings.Repeat("a", 64)
			started, release := make(chan struct{}), make(chan struct{})
			var releaseOnce sync.Once
			var calls atomic.Int64
			server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/preload" {
					http.NotFound(w, r)
					return
				}
				if calls.Add(1) == 1 {
					close(started)
					<-release
				}
				_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{Status: "ready", Ready: true, Requested: 1, Warm: 1,
					Results: []sidecar.PreloadResult{{PromptContractID: contract, Status: "warm"}}})
			}))
			defer func() { releaseOnce.Do(func() { close(release) }); server.Close() }()
			client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket})
			defer client.Close()
			state := catalog.New()
			active := []catalog.Status{{ModelID: "model", PromptContractID: contract, ArtifactReady: true}}
			state.Replace(active)
			child := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
			controller, err := preload.New(state, child, client, preload.PreloadControllerConfig{})
			if err != nil {
				t.Fatal(err)
			}
			done := make(chan struct{})
			go func() { defer close(done); controller.Reconcile(context.Background()) }()
			select {
			case <-started:
			case <-time.After(3 * time.Second):
				t.Fatal("preload did not reach transport barrier")
			}
			if changed == "catalog" {
				state.Replace(active)
			} else {
				child.replace(preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 2})
			}
			releaseOnce.Do(func() { close(release) })
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				t.Fatal("preload did not finish after barrier release")
			}
			if controller.Status().Ready || controller.ReadyFor(contract) {
				t.Fatal("successful response from obsolete generation opened routing")
			}
			controller.Reconcile(context.Background())
			if !controller.ReadyFor(contract) || calls.Load() != 2 {
				t.Fatalf("replacement generation failed to preload: status=%+v calls=%d", controller.Status(), calls.Load())
			}
		})
	}
}
