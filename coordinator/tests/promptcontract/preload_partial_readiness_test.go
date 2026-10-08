package promptcontract_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

// This is the Go controller gate only. The actual Rust readiness/permit
// behavior requires separate paired protocol and real-sidecar qualification.
func TestPreloadHealthyContractSurvivesUnrelatedProvisioning(t *testing.T) {
	for _, failed := range []bool{false, true} {
		name := "pending"
		if failed {
			name = "failed"
		}
		t.Run(name, func(t *testing.T) {
			contractA, contractB := strings.Repeat("a", 64), strings.Repeat("b", 64)
			var calls atomic.Int64
			server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/v1/preload" {
					http.NotFound(w, r)
					return
				}
				var input struct {
					PromptContractIDs []string `json:"prompt_contract_ids"`
				}
				if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
					t.Error(err)
					return
				}
				if len(input.PromptContractIDs) != 1 || input.PromptContractIDs[0] != contractA {
					t.Error("preload included an unverified artifact")
				}
				calls.Add(1)
				_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{Status: "ready", Ready: true,
					Requested: 1, Warm: 1, Results: []sidecar.PreloadResult{{PromptContractID: contractA, Status: "warm"}}})
			}))
			defer server.Close()
			client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
			defer client.Close()
			unavailable := catalog.Status{ModelID: "model-b", PromptContractID: contractB}
			if failed {
				unavailable.LastError = "synthetic artifact failure"
			}
			provisioner := catalog.New()
			provisioner.Replace([]catalog.Status{
				{ModelID: "model-a", ArtifactReady: true, PromptContractID: contractA, ModelAggregateSHA256: strings.Repeat("e", 64)}, unavailable,
			})
			supervisor := &preloadChildFixture{status: preload.ChildStatus{
				Running: true, Ready: true, ChildGeneration: 1,
			}}
			controller, err := preload.New(provisioner, supervisor, client, preload.PreloadControllerConfig{})
			if err != nil {
				t.Fatal(err)
			}
			controller.Reconcile(context.Background())
			if !controller.ReadyFor(contractA) || calls.Load() != 1 {
				t.Errorf("unrelated %s contract suppressed verified A: status=%+v calls=%d", name, controller.Status(), calls.Load())
			}
			if controller.ReadyFor(contractB) {
				t.Error("unverified B became ready")
			}
		})
	}
}

func TestPreloadPartialSuccessPreservesOnlyCurrentVerifiedContract(t *testing.T) {
	contractA, contractB := strings.Repeat("a", 64), strings.Repeat("b", 64)
	var calls atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ready" {
			_ = json.NewEncoder(w).Encode(sidecar.ReadinessStatus{Status: "ok", Ready: true})
			return
		}
		if r.URL.Path != "/v1/preload" {
			http.NotFound(w, r)
			return
		}
		calls.Add(1)
		_ = json.NewEncoder(w).Encode(sidecar.PreloadReport{Status: "degraded", Requested: 2, Warm: 1, Failed: 1,
			Results: []sidecar.PreloadResult{{PromptContractID: contractA, Status: "warm"}, {PromptContractID: contractB, Status: "failed"}}})
	}))
	defer server.Close()
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	defer client.Close()
	provisioner := catalog.New()
	provisioner.Replace([]catalog.Status{
		{ModelID: "model-a", ArtifactReady: true, PromptContractID: contractA, ModelAggregateSHA256: strings.Repeat("e", 64)},
		{ModelID: "model-b", ArtifactReady: true, PromptContractID: contractB, ModelAggregateSHA256: strings.Repeat("e", 64)},
	})
	supervisor := &preloadChildFixture{status: preload.ChildStatus{
		Running: true, Ready: true, ChildGeneration: 1,
	}}
	controller, err := preload.New(provisioner, supervisor, client, preload.PreloadControllerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(contractA) || controller.ReadyFor(contractB) || calls.Load() != 1 {
		t.Errorf("partial preload discarded successful A or admitted failed B: status=%+v calls=%d", controller.Status(), calls.Load())
	}
	controller.Reconcile(context.Background())
	if !controller.ReadyFor(contractA) || calls.Load() != 1 {
		t.Error("failed-member backoff erased successful readiness or retried immediately")
	}
	// These are retained safety controls, not claims of newly broken behavior.
	// The next catalog generation retains model-b's verified artifact only.
	provisioner.Replace([]catalog.Status{{ModelID: "model-b", ArtifactReady: true, PromptContractID: contractB, ModelAggregateSHA256: strings.Repeat("e", 64)}})
	if controller.ReadyFor(contractA) {
		t.Error("catalog removal did not immediately revoke A")
	}
	supervisor.replace(preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 2})
	if controller.ReadyFor(contractA) || controller.ReadyFor(contractB) {
		t.Error("replacement child inherited old readiness")
	}
}
