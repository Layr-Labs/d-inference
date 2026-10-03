package catalog_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

type revisionAliasFailureStore struct {
	store.Store
	fail atomic.Bool
}

func (s *revisionAliasFailureStore) ListModelAliases() ([]store.ModelAlias, error) {
	if s.fail.Load() {
		return nil, errors.New("alias store unavailable")
	}
	return s.Store.ListModelAliases()
}

func TestPublishRevisionRetriesAliasRefreshBeforeDeliveringDesiredTarget(t *testing.T) {
	for _, lineage := range []string{"previous", "retired"} {
		t.Run(lineage, func(t *testing.T) {
			backing := &revisionAliasFailureStore{Store: memory.NewMemory(store.Config{})}
			srv, st, manifest := revisionPublishFixture(t, backing)
			srv.SetChallengeInterval(time.Hour)
			const oldBuild = "old-alias-build"
			seedActiveModel(t, st, oldBuild, "Old build")
			alias := &store.ModelAlias{
				AliasID: "revision-alias", DisplayName: "Revision alias", Active: true,
				DesiredBuild: manifest.ModelID,
			}
			if lineage == "previous" {
				alias.PreviousBuild = oldBuild
			} else {
				alias.RetiredBuilds = []string{oldBuild}
			}
			if err := st.UpsertModelAlias(alias); err != nil {
				t.Fatal(err)
			}
			// Reproduce a failed startup alias refresh: catalog reads succeed,
			// but a provider on the old lineage cannot learn the new target.
			backing.fail.Store(true)
			srv.SyncModelCatalog()
			ts := httptest.NewServer(srv.Handler())
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close(websocket.StatusNormalClosure, "")
			message := protocol.RegisterMessage{
				Type:     protocol.TypeRegister,
				Hardware: protocol.Hardware{MachineModel: "Mac15,8", ChipName: "Apple M3 Max", MemoryGB: 64},
				Models:   []protocol.ModelInfo{{ID: oldBuild, ModelType: "chat", Quantization: "4bit", WeightHash: testHash}},
				Backend:  registry.BackendMLXSwift, Version: "0.9.9",
				RuntimeCapabilities:     []string{"model_revisions_v1"},
				PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
				EncryptedResponseChunks: true, PrivacyCapabilities: testkit.PrivacyCaps(),
			}
			data, err := json.Marshal(message)
			if err != nil {
				t.Fatal(err)
			}
			if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
				t.Fatal(err)
			}
			readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
				return len(msg.Models) == 1 && msg.Models[0].DesiredBuild == oldBuild
			}, "old concrete build before alias recovery")

			body := map[string]any{"version": manifest.Version}
			response := publishRevisionRequest(t, srv, manifest.ModelID, body)
			if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") == "" {
				t.Fatalf("failed alias refresh acknowledged: %d %s", response.Code, response.Body.String())
			}
			committed, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil || committed.ActiveVersion.Version != manifest.Version {
				t.Fatal("expected durable promotion before alias refresh failed", err)
			}
			if srv.registry.IsAlias(alias.AliasID) {
				t.Fatal("failure fixture unexpectedly loaded the alias")
			}

			backing.fail.Store(false)
			response = publishRevisionRequest(t, srv, manifest.ModelID, body)
			if response.Code != http.StatusOK {
				t.Fatalf("retry: %d %s", response.Code, response.Body.String())
			}
			readDesiredModels(ctx, t, conn, func(msg protocol.DesiredModelsMessage) bool {
				return len(msg.Models) == 1 && msg.Models[0].ModelName == alias.AliasID &&
					msg.Models[0].DesiredBuild == manifest.ModelID && msg.Models[0].Revision == manifest.Version &&
					msg.Models[0].AggregateSHA256 == manifest.AggregateSHA256
			}, "promoted revision after alias recovery")
		})
	}
}

func TestRevisionRollbackAndRetirementRetryAliasRefresh(t *testing.T) {
	for _, action := range []string{"promote", "retire-revision"} {
		t.Run(action, func(t *testing.T) {
			backing := &revisionAliasFailureStore{Store: memory.NewMemory(store.Config{})}
			srv, st, manifest := revisionPublishFixture(t, backing)
			original, err := st.GetModelRegistryRecord(manifest.ModelID)
			if err != nil {
				t.Fatal(err)
			}
			if response := publishRevisionRequest(t, srv, manifest.ModelID, map[string]any{"version": manifest.Version}); response.Code != http.StatusOK {
				t.Fatalf("initial publication: %d %s", response.Code, response.Body.String())
			}
			backing.fail.Store(true)
			body := map[string]any{"version": original.ActiveVersion.Version}
			response := modelRevisionActionRequest(t, srv, manifest.ModelID, action, body)
			if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") == "" {
				t.Fatalf("failed alias refresh acknowledged: %d %s", response.Code, response.Body.String())
			}
			// Alias failure must not prevent the already-committed hash policy
			// from being applied, especially withdrawal of a retired revision.
			if action == "promote" && srv.registry.CatalogWeightHash(manifest.ModelID) != original.ActiveVersion.AggregateSHA256 {
				t.Fatal("rollback hash policy was not applied")
			}
			if action == "retire-revision" && srv.registry.CatalogAcceptsWeightHash(manifest.ModelID, original.ActiveVersion.AggregateSHA256) {
				t.Fatal("retired hash remained approved after alias refresh failed")
			}
			backing.fail.Store(false)
			response = modelRevisionActionRequest(t, srv, manifest.ModelID, action, body)
			if response.Code != http.StatusOK {
				t.Fatalf("retry: %d %s", response.Code, response.Body.String())
			}
		})
	}
}
