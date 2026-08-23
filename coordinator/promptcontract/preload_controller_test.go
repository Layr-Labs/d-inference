package promptcontract

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
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
		results := make([]PreloadResult, len(request.PromptContractIDs))
		for index, contractID := range request.PromptContractIDs {
			results[index] = PreloadResult{PromptContractID: contractID, Status: "warm"}
		}
		_ = json.NewEncoder(w).Encode(PreloadReport{
			Status: "ready", Ready: true, Requested: len(results), Warm: len(results), Results: results,
		})
	}))
	defer server.Close()
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	defer client.Close()
	provisioner := &Provisioner{generation: 1, statuses: map[string]ProvisionStatus{
		"model-a": {ArtifactReady: true, PromptContractID: contractA},
		"model-b": {ArtifactReady: true, PromptContractID: contractA},
	}}
	supervisor := &Supervisor{
		client: client,
		status: SupervisorStatus{
			Enabled: true, Running: true, Ready: true, ChildGeneration: 1,
		},
	}
	controller, err := NewPreloadController(provisioner, supervisor, PreloadControllerConfig{})
	if err != nil {
		t.Fatal(err)
	}

	controller.reconcile(context.Background())
	if !controller.ReadyFor(contractA) || preloadCalls.Load() != 1 {
		t.Fatalf("initial preload status=%+v calls=%d", controller.Status(), preloadCalls.Load())
	}
	if status := controller.Status(); status.ContractCount != 1 || status.Warm != 1 || status.Runs != 1 {
		t.Fatalf("deduplicated preload status=%+v", status)
	}

	supervisor.mu.Lock()
	supervisor.status.ChildGeneration = 2
	supervisor.mu.Unlock()
	if controller.ReadyFor(contractA) {
		t.Fatal("old child generation remained ready")
	}
	controller.reconcile(context.Background())
	if !controller.ReadyFor(contractA) || preloadCalls.Load() != 2 {
		t.Fatalf("replacement child was not re-preloaded: status=%+v calls=%d",
			controller.Status(), preloadCalls.Load())
	}

	provisioner.mu.Lock()
	provisioner.generation = 2
	provisioner.statuses = map[string]ProvisionStatus{"model-c": {PromptContractID: contractB}}
	provisioner.mu.Unlock()
	if controller.ReadyFor(contractA) || controller.ReadyFor(contractB) {
		t.Fatal("pending catalog generation remained ready")
	}
	controller.reconcile(context.Background())
	if preloadCalls.Load() != 2 || controller.Status().Ready {
		t.Fatalf("pending artifacts triggered preload: status=%+v calls=%d",
			controller.Status(), preloadCalls.Load())
	}

	provisioner.mu.Lock()
	provisioner.statuses["model-c"] = ProvisionStatus{ArtifactReady: true, PromptContractID: contractB}
	provisioner.mu.Unlock()
	controller.reconcile(context.Background())
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
		_ = json.NewEncoder(w).Encode(PreloadReport{
			Status: "degraded", Requested: 1, Failed: 1,
			Results: []PreloadResult{{PromptContractID: contractID, Status: "failed"}},
		})
	}))
	defer server.Close()
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	defer client.Close()
	provisioner := &Provisioner{generation: 1, statuses: map[string]ProvisionStatus{
		"model": {ArtifactReady: true, PromptContractID: contractID},
	}}
	supervisor := &Supervisor{client: client, status: SupervisorStatus{
		Enabled: true, Running: true, Ready: true, ChildGeneration: 1,
	}}
	controller, err := NewPreloadController(provisioner, supervisor, PreloadControllerConfig{
		FailureBackoffMin: 40 * time.Millisecond,
		FailureBackoffMax: 80 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}

	controller.reconcile(context.Background())
	controller.reconcile(context.Background())
	if preloadCalls.Load() != 1 {
		t.Fatalf("failure retried without backoff: calls=%d", preloadCalls.Load())
	}
	controller.mu.RLock()
	firstBackoff := controller.failureBackoff
	controller.mu.RUnlock()
	if firstBackoff != 40*time.Millisecond {
		t.Fatalf("first backoff = %s, want 40ms", firstBackoff)
	}
	expireControllerRetry(controller)
	controller.reconcile(context.Background())
	controller.reconcile(context.Background())
	if preloadCalls.Load() != 2 {
		t.Fatalf("first retry calls=%d, want 2", preloadCalls.Load())
	}
	controller.mu.RLock()
	secondBackoff := controller.failureBackoff
	controller.mu.RUnlock()
	if secondBackoff != 80*time.Millisecond {
		t.Fatalf("second backoff = %s, want 80ms", secondBackoff)
	}
	controller.reconcile(context.Background())
	if preloadCalls.Load() != 2 {
		t.Fatalf("exponential backoff did not defer retry: calls=%d", preloadCalls.Load())
	}

	// A new child generation is new state and retries immediately.
	supervisor.mu.Lock()
	supervisor.status.ChildGeneration = 2
	supervisor.mu.Unlock()
	controller.reconcile(context.Background())
	if preloadCalls.Load() != 3 {
		t.Fatalf("new generation did not reset failure backoff: calls=%d", preloadCalls.Load())
	}
}

func expireControllerRetry(controller *PreloadController) {
	controller.mu.Lock()
	controller.retryAt = time.Now().Add(-time.Nanosecond)
	controller.mu.Unlock()
}
