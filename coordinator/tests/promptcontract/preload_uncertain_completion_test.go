package promptcontract_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

func TestPreloadContinuityUnknownCompletionPreservesIncumbents(t *testing.T) {
	input := activeSetInput(10, 8)
	var calls atomic.Int64
	server, socket := startUnixHTTPServer(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v2/preload" {
			http.NotFound(w, r)
			return
		}
		if calls.Add(1) > 1 {
			conn, _, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			_ = conn.Close() // real control transport EOF: native completion unknown
			return
		}
		var request struct {
			IDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Error(err)
			return
		}
		report := readinessReport(request.IDs, "")
		report.ContinuityVersion = 1
		_ = json.NewEncoder(w).Encode(report)
	}))
	t.Cleanup(func() { _ = server.Close() })
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	provisioner := catalog.New()
	statuses := make([]catalog.Status, len(input.Verified))
	for i, v := range input.Verified {
		statuses[i] = catalog.Status{ModelID: v.ModelID, ModelAggregateSHA256: v.ModelAggregateSHA256, PromptContractID: v.PromptContractID, ArtifactReady: true}
	}
	provisioner.Replace(statuses)
	child := &preloadChildFixture{status: preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}}
	now := time.Duration(0)
	controller, err := preload.New(provisioner, child, client, preload.PreloadControllerConfig{PolicyNow: func() time.Duration { return now }, FailureBackoffMin: time.Hour, FailureBackoffMax: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	controller.SetSelectionSource(func(v []preload.VerifiedPreloadArtifact, _ bool) ([]preload.PreloadDemandIdentity, []string) {
		return slices.Clone(v), nil
	})
	_, verified := provisioner.VerifiedPreloadArtifacts()
	for _, v := range verified[:8] {
		if !controller.NoteDemand(v) {
			t.Fatal("initial demand refused")
		}
	}
	controller.Reconcile(context.Background())
	if controller.Status().ContractCount != 8 {
		t.Fatalf("setup=%+v", controller.Status())
	}
	for _, v := range verified[8:] {
		if !controller.NoteDemand(v) {
			t.Fatal("waiting demand refused")
		}
	}
	for _, tick := range []time.Duration{30 * time.Second, 60 * time.Second, 90 * time.Second, 120 * time.Second} {
		now = tick
		controller.Reconcile(context.Background())
		for _, v := range verified[1:8] {
			if !controller.PlanningState(v).Participating {
				t.Fatalf("acknowledged incumbent %s evicted after unknown completion at %v: %+v", v.ModelID, tick, controller.Status())
			}
		}
		if controller.Status().ContractCount != 7 {
			t.Fatalf("retained count=%d at %v", controller.Status().ContractCount, tick)
		}
		for _, v := range verified[8:] {
			if controller.ReadyFor(v.PromptContractID) {
				t.Fatal("unknown newcomer became acknowledged")
			}
		}
	}
}
