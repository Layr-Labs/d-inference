package api

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestModelRevisionRollbackDoesNotAcknowledgeFailedRefreshOrDelivery(t *testing.T) {
	for _, failure := range []string{"catalog", "delivery"} {
		t.Run(failure, func(t *testing.T) {
			backing := &revisionCatalogFailureStore{Store: memory.NewMemory(store.Config{})}
			srv, st, manifest := revisionPublishFixture(t, backing)
			original, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil {
				t.Fatal(err)
			}
			if response := publishRevisionRequest(t, srv, manifest.ModelID, map[string]any{"version": manifest.Version}); response.Code != http.StatusOK {
				t.Fatalf("initial publication: %d %s", response.Code, response.Body.String())
			}
			if failure == "catalog" {
				backing.fail.Store(true)
			} else {
				registerBuildsProvider(srv, "failed-rollback-recipient", manifest.ModelID)
			}
			body := map[string]any{"version": original.ActiveVersion.Version}
			response := modelRevisionActionRequest(t, srv, manifest.ModelID, "promote", body)
			if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") == "" {
				t.Fatalf("incomplete rollback acknowledged: %d %s", response.Code, response.Body.String())
			}
			committed, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil || committed.ActiveVersion.Version != original.ActiveVersion.Version {
				t.Fatal("rollback was not committed before refresh/delivery failure", err)
			}
			backing.fail.Store(false)
			srv.registry.Disconnect("failed-rollback-recipient")
			response = modelRevisionActionRequest(t, srv, manifest.ModelID, "promote", body)
			if response.Code != http.StatusOK {
				t.Fatalf("rollback retry: %d %s", response.Code, response.Body.String())
			}
			if srv.registry.CatalogWeightHash(manifest.ModelID) != original.ActiveVersion.AggregateSHA256 {
				t.Fatal("rollback retry did not restore the original routing policy")
			}
		})
	}
}
