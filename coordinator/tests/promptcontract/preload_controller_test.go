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
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestPreloadControllerGatesCatalogAndChildGenerations(t *testing.T) {
	contractA := strings.Repeat("a", 64)
	contractB := strings.Repeat("b", 64)
	var preloadCalls atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/preload" {
			http.NotFound(w, r)
			return
		}
		var request struct {
			PromptContractIDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		preloadCalls.Add(1)
		results := make([]sidecar.PreloadResult, len(request.PromptContractIDs))
		for index, contractID := range request.PromptContractIDs {
			results[index] = sidecar.PreloadResult{PromptContractID: contractID, Status: "warm"}
		}
		_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{
			Status: "ready", Ready: true, Requested: len(results), Warm: len(results), Results: results,
		})
	}))
	defer server.Close()
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	defer client.Close()
	provisioner := catalog.New()
	provisioner.Replace([]catalog.Status{
		{ModelID: "model-a", ArtifactReady: true, PromptContractID: contractA},
		{ModelID: "model-b", ArtifactReady: true, PromptContractID: contractA},
	})
	supervisor := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	controller, err := preload.New(provisioner, supervisor, client, preload.PreloadControllerConfig{})
	if err != nil {
		t.Fatal(err)
	}

	controller.Reconcile(context.Background())
	if !controller.ReadyFor(contractA) || preloadCalls.Load() != 1 {
		t.Fatalf("initial preload status=%+v calls=%d", controller.Status(), preloadCalls.Load())
	}
	if status := controller.Status(); status.ContractCount != 1 || status.Warm != 1 || status.Runs != 1 {
		t.Fatalf("deduplicated preload status=%+v", status)
	}

	supervisor.replace(preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 2})
	if controller.ReadyFor(contractA) {
		t.Fatal("old child generation remained ready")
	}
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(contractA) || preloadCalls.Load() != 2 {
		t.Fatalf("replacement child was not re-preloaded: status=%+v calls=%d",
			controller.Status(), preloadCalls.Load())
	}

	generation := provisioner.Replace([]catalog.Status{{ModelID: "model-c", PromptContractID: contractB}})
	if controller.ReadyFor(contractA) || controller.ReadyFor(contractB) {
		t.Fatal("pending catalog generation remained ready")
	}
	controller.Reconcile(context.Background())
	if preloadCalls.Load() != 2 || controller.Status().Ready {
		t.Fatalf("pending artifacts triggered preload: status=%+v calls=%d",
			controller.Status(), preloadCalls.Load())
	}

	provisioner.Record(generation, "model-c", "", nil, nil)
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(contractB) || controller.ReadyFor(contractA) || preloadCalls.Load() != 3 {
		t.Fatalf("new catalog did not replace ready set: status=%+v calls=%d",
			controller.Status(), preloadCalls.Load())
	}
}

func TestPreloadControllerBacksOffDeterministicFailures(t *testing.T) {
	contractID := strings.Repeat("a", 64)
	var preloadCalls atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		preloadCalls.Add(1)
		_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{
			Status: "degraded", Requested: 1, Failed: 1,
			Results: []sidecar.PreloadResult{{PromptContractID: contractID, Status: "failed"}},
		})
	}))
	defer server.Close()
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	defer client.Close()
	provisioner := catalog.New()
	provisioner.Replace([]catalog.Status{{ModelID: "model", ArtifactReady: true, PromptContractID: contractID}})
	supervisor := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	controller, err := preload.New(provisioner, supervisor, client, preload.PreloadControllerConfig{
		FailureBackoffMin: 40 * time.Millisecond,
		FailureBackoffMax: 80 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}

	controller.Reconcile(context.Background())
	controller.Reconcile(context.Background())
	if preloadCalls.Load() != 1 {
		t.Fatalf("failure retried without backoff: calls=%d", preloadCalls.Load())
	}
	time.Sleep(45 * time.Millisecond)
	controller.Reconcile(context.Background())
	controller.Reconcile(context.Background())
	if preloadCalls.Load() != 2 {
		t.Fatalf("first retry calls=%d, want 2", preloadCalls.Load())
	}
	time.Sleep(45 * time.Millisecond)
	controller.Reconcile(context.Background())
	if preloadCalls.Load() != 2 {
		t.Fatalf("exponential backoff did not grow: calls=%d", preloadCalls.Load())
	}

	// A new child generation is new state and retries immediately.
	supervisor.replace(preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 2})
	controller.Reconcile(context.Background())
	if preloadCalls.Load() != 3 {
		t.Fatalf("new generation did not reset failure backoff: calls=%d", preloadCalls.Load())
	}
}

type preloadChildFixture struct {
	mu     sync.RWMutex
	status preload.ChildStatus
}

func (f *preloadChildFixture) Status() preload.ChildStatus {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.status
}

func (f *preloadChildFixture) replace(status preload.ChildStatus) {
	f.mu.Lock()
	f.status = status
	f.mu.Unlock()
}
