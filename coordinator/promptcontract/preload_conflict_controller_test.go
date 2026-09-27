package promptcontract

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// This control also compiles on the original D64 controller: HTTP 409 did not
// accept a Rust replacement and must not become a failed-tokenizer/backoff event.
func TestPreloadControllerConflictDoesNotBecomeFailedRuntimeLoad(t *testing.T) {
	id := strings.Repeat("a", 64)
	var calls atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			http.Error(w, "preload already in progress", http.StatusConflict)
			return
		}
		_ = json.NewEncoder(w).Encode(PreloadReport{Status: "ready", Ready: true, Requested: 1, Warm: 1,
			Results: []PreloadResult{{PromptContractID: id, Status: "warm"}}})
	}))
	t.Cleanup(func() { _ = server.Close() })
	client := NewClient(ClientConfig{SocketPath: socket, MaxPreloadIDs: 1})
	t.Cleanup(client.Close)
	provisioner := &Provisioner{generation: 1, statuses: map[string]ProvisionStatus{
		"fixture": {ArtifactReady: true, PromptContractID: id, ModelAggregateSHA256: strings.Repeat("b", 64)},
	}}
	supervisor := &Supervisor{client: client, status: SupervisorStatus{Running: true, Ready: true, ChildGeneration: 1}}
	controller, err := NewPreloadController(provisioner, supervisor, PreloadControllerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	controller.reconcile(context.Background())
	if controller.Status().Failures != 0 || controller.Status().Ready || controller.failureBackoff != 0 {
		t.Fatal("409 changed failed-load accounting, backoff or publication")
	}
	controller.reconcile(context.Background())
	if !controller.ReadyFor(id) || controller.Status().Runs != 1 || controller.Status().Failures != 0 || calls.Load() != 2 {
		t.Fatal("unaccepted conflict prevented immediate independent recovery")
	}
}
