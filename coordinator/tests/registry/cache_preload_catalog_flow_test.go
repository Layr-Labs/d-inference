package registry_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type catalogPreloadChild struct{}

func (catalogPreloadChild) Status() preload.ChildStatus {
	return preload.ChildStatus{Running: true, Ready: true, ChildGeneration: 1}
}

func TestCachePreloadConfiguredCatalogControllerFlow(t *testing.T) {
	artifact := artifactTestIdentity()
	r := production.New(testLogger())
	if err := r.ConfigureCacheRouting(artifactTestConfig([]production.CacheRoutingArtifact{artifact})); err != nil {
		t.Fatal(err)
	}
	r.SetModelCatalog([]production.CatalogEntry{{ID: artifact.ModelID, WeightHash: artifact.ModelAggregateSHA256}})
	catalogState := catalog.New()
	statuses := make([]catalog.Status, 129)
	for i := range statuses {
		statuses[i] = catalog.Status{ModelID: fmt.Sprintf("catalog-%03d", i), ArtifactReady: true, ModelAggregateSHA256: artifact.ModelAggregateSHA256, PromptContractID: fmt.Sprintf("%064x", i%8+1)}
	}
	statuses[128].ModelID = artifact.ModelID
	statuses[128].PromptContractID = artifact.PromptContractID
	// Keep eight distinct contracts across129 models.
	for i := range statuses {
		if i%8 == 0 {
			statuses[i].PromptContractID = artifact.PromptContractID
		}
	}
	catalogState.Replace(statuses)
	dir, err := os.MkdirTemp("/tmp", "pc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	socket := filepath.Join(dir, "s")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	var batches atomic.Int64
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/v2/preload" {
			http.NotFound(w, req)
			return
		}
		var input struct {
			IDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(req.Body).Decode(&input); err != nil {
			t.Error(err)
			return
		}
		if len(input.IDs) != 8 {
			t.Errorf("native request has %d IDs, want 8", len(input.IDs))
		}
		batches.Add(1)
		report := sidecar.PreloadReport{Status: "ready", Ready: true, Requested: len(input.IDs), Warm: len(input.IDs), ContinuityVersion: 1}
		for _, id := range input.IDs {
			report.Results = append(report.Results, sidecar.PreloadResult{PromptContractID: id, Status: "warm"})
		}
		_ = json.NewEncoder(w).Encode(report)
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	client := sidecar.NewClient(sidecar.ClientConfig{SocketPath: socket, MaxPreloadIDs: 8})
	t.Cleanup(client.Close)
	controller, err := preload.New(catalogState, catalogPreloadChild{}, client, preload.PreloadControllerConfig{MaxCatalogModels: 129})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(controller.Close)
	if !controller.SetSelectionSource(func(v []preload.VerifiedPreloadArtifact, _ bool) ([]preload.PreloadDemandIdentity, []string) {
		return r.CachePreloadIdentities(v), nil
	}) {
		t.Fatal("selection source refused")
	}
	controller.Reconcile(context.Background())
	snapshot, v := catalogState.VerifiedPreloadArtifacts()
	if snapshot.Counts.Ready != 129 || len(v) != 129 || controller.Status().ContractCount != 8 {
		t.Fatalf("full configured catalog not preloaded: catalog=%+v status=%+v", snapshot, controller.Status())
	}
	var allowed preload.PreloadDemandIdentity
	for _, identity := range v {
		if identity.ModelID == artifact.ModelID {
			allowed = identity
		}
	}
	if !controller.PlanningState(allowed).Participating {
		t.Fatalf("allowlisted model not participating: %+v", controller.Status())
	}
	for _, identity := range v {
		if identity.ModelID != artifact.ModelID && controller.PlanningState(identity).Participating {
			t.Fatal("projection widened authorization")
		}
	}
	if batches.Load() != 1 {
		t.Fatalf("preload batches=%d", batches.Load())
	}
	// Actual Client capacity still refuses a ninth contract.
	_, err = client.PreloadContinuous(context.Background(), append(snapshot.ContractIDs, fmt.Sprintf("%064x", 99)), true)
	if err != sidecar.ErrPreloadRejected {
		t.Fatalf("native capacity widened: %v", err)
	}
}
