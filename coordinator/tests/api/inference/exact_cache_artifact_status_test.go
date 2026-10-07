package inference_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"log/slog"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestExactCacheArtifactStatusPreservesEmptyWithoutExposingIdentities(t *testing.T) {
	for _, tc := range []struct {
		name       string
		artifacts  []registry.CacheRoutingArtifact
		configured bool
	}{
		{name: "absent"},
		{name: "empty", artifacts: []registry.CacheRoutingArtifact{}, configured: true},
		{name: "restricted", artifacts: []registry.CacheRoutingArtifact{{
			ModelID: "private-model", ModelAggregateSHA256: strings.Repeat("a", 64),
			PromptContractID: strings.Repeat("b", 64),
		}}, configured: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.DiscardHandler)
			reg := registry.New(logger)
			cfg := reg.CacheRoutingConfigSnapshot()
			cfg.AllowedArtifacts = tc.artifacts
			if err := reg.ConfigureCacheRouting(cfg); err != nil {
				t.Fatal(err)
			}
			srv := newComposedServer(reg, memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
			t.Cleanup(srv.Close)
			status := srv.ExactCacheStatusSnapshot()
			if status.ArtifactAllowlist.Configured != tc.configured || status.ArtifactAllowlist.Count != len(tc.artifacts) {
				t.Fatalf("artifact status=%+v", status.ArtifactAllowlist)
			}
			data, err := json.Marshal(status)
			if err != nil {
				t.Fatal(err)
			}
			for _, sensitive := range []string{"private-model", strings.Repeat("a", 64), strings.Repeat("b", 64)} {
				if strings.Contains(string(data), sensitive) {
					t.Fatalf("status exposed %q", sensitive)
				}
			}
			gauges := srv.observation.Metrics().Snapshot().Gauges
			if gauges["exact_cache_artifact_allowlist_configured"] != observation.BoolGauge(tc.configured) ||
				gauges["exact_cache_artifact_allowlist_count"] != float64(len(tc.artifacts)) {
				t.Fatalf("artifact gauges=%v", gauges)
			}
		})
	}
}

func staleAllowlistFixture(t *testing.T, logger *slog.Logger) (*serverFixture, registry.CacheRoutingArtifact) {
	t.Helper()
	srv := newComposedServer(registry.New(logger), memory.NewMemory(store.Config{}), TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	status := provisionPromptArtifact(t, srv.Owner, "revised-model")
	return srv, registry.CacheRoutingArtifact{
		ModelID: status.ModelID, ModelAggregateSHA256: status.ModelAggregateSHA256,
		PromptContractID: status.PromptContractID,
	}
}

func configureStaleAllowlistTest(t *testing.T, srv *serverFixture, mode string, artifacts []registry.CacheRoutingArtifact) {
	t.Helper()
	if err := srv.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: mode, ActivationPct: 100, AllowedArtifacts: artifacts,
		MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
}

// A model revision leaves its allowlist entry naming the previous artifact,
// which silently removes the model from cache routing. The status counts such
// models so the gap is visible without exposing which model it is.
func TestExactCacheStatusCountsModelsListedOnlyUnderASupersededArtifact(t *testing.T) {
	for _, tc := range []struct {
		name      string
		mode      string
		allowlist func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact
		stale     int
	}{
		{name: "unrestricted", mode: registry.CacheRoutingOn,
			allowlist: func(registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact { return nil }},
		{name: "live artifact listed", mode: registry.CacheRoutingOn,
			allowlist: func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact {
				return []registry.CacheRoutingArtifact{live}
			}},
		{name: "model never listed", mode: registry.CacheRoutingOn,
			allowlist: func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact {
				live.ModelID = "other-model"
				return []registry.CacheRoutingArtifact{live}
			}},
		{name: "previous weights listed", mode: registry.CacheRoutingOn, stale: 1,
			allowlist: func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact {
				live.ModelAggregateSHA256 = strings.Repeat("a", 64)
				return []registry.CacheRoutingArtifact{live}
			}},
		{name: "previous template listed", mode: registry.CacheRoutingOn, stale: 1,
			allowlist: func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact {
				live.PromptContractID = strings.Repeat("b", 64)
				return []registry.CacheRoutingArtifact{live}
			}},
		{name: "previous and live listed", mode: registry.CacheRoutingOn,
			allowlist: func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact {
				previous := live
				previous.ModelAggregateSHA256 = strings.Repeat("a", 64)
				return []registry.CacheRoutingArtifact{previous, live}
			}},
		{name: "routing off", mode: registry.CacheRoutingOff,
			allowlist: func(live registry.CacheRoutingArtifact) []registry.CacheRoutingArtifact {
				live.ModelAggregateSHA256 = strings.Repeat("a", 64)
				return []registry.CacheRoutingArtifact{live}
			}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, live := staleAllowlistFixture(t, slog.New(slog.DiscardHandler))
			configureStaleAllowlistTest(t, srv, tc.mode, tc.allowlist(live))
			status := srv.ExactCacheStatusSnapshot()
			if status.ArtifactAllowlist.StaleModels != tc.stale {
				t.Fatalf("stale_models=%d, want %d", status.ArtifactAllowlist.StaleModels, tc.stale)
			}
			data, err := json.Marshal(status)
			if err != nil {
				t.Fatal(err)
			}
			for _, identity := range []string{live.ModelID, live.ModelAggregateSHA256, live.PromptContractID} {
				if strings.Contains(string(data), identity) {
					t.Fatalf("status exposed %q", identity)
				}
			}
			if gauge := srv.observation.Metrics().Snapshot().Gauges["exact_cache_artifact_allowlist_stale_models"]; gauge != float64(tc.stale) {
				t.Fatalf("stale gauge=%v, want %d", gauge, tc.stale)
			}
		})
	}
}

// A catalog sync republishes every identity as pending before its files are
// fetched. The count must not wait for that download, or it would drop to zero
// and warn again on every sync.
func TestStaleAllowlistCountDoesNotWaitForArtifactDownload(t *testing.T) {
	srv, previous := staleAllowlistFixture(t, slog.New(slog.DiscardHandler))
	// The fixture origin does not serve this revision, so it never becomes ready.
	srv.ReconcilePromptArtifacts([]store.ModelRegistryRecord{{
		ModelRegistryEntry: store.ModelRegistryEntry{ID: previous.ModelID},
		ActiveVersion:      &store.ModelVersion{R2Prefix: "models/unfetched", AggregateSHA256: strings.Repeat("d", 64)},
		Files: []store.ModelVersionFile{{
			Path: "tokenizer.json", SizeBytes: 1, SHA256: strings.Repeat("e", 64), Role: "tokenizer",
		}},
	}})
	configureStaleAllowlistTest(t, srv, registry.CacheRoutingOn, []registry.CacheRoutingArtifact{previous})

	stale := srv.ExactCacheStatusSnapshot().ArtifactAllowlist.StaleModels
	if revision, _ := srv.PromptArtifactStatus(previous.ModelID); revision.ArtifactReady || stale != 1 {
		t.Fatalf("stale_models=%d for an unfetched revision (ready=%t), want 1", stale, revision.ArtifactReady)
	}
}

// The public status only counts. The operator log names the exact tuple to
// append, once per occurrence rather than on every status read.
func TestStaleAllowlistWarningNamesTheMissingTupleOncePerOccurrence(t *testing.T) {
	logs := &lockedBuffer{}
	srv, live := staleAllowlistFixture(t, slog.New(slog.NewJSONHandler(logs, nil)))
	previous := live
	previous.ModelAggregateSHA256 = strings.Repeat("a", 64)
	warnings := func() []map[string]any {
		var records []map[string]any
		for line := range strings.SplitSeq(logs.String(), "\n") {
			var record map[string]any
			if json.Unmarshal([]byte(line), &record) == nil && record["prompt_contract_id"] != nil {
				records = append(records, record)
			}
		}
		return records
	}

	configureStaleAllowlistTest(t, srv, registry.CacheRoutingOn, []registry.CacheRoutingArtifact{previous})
	srv.ExactCacheStatusSnapshot()
	srv.ExactCacheStatusSnapshot()
	logged := warnings()
	if len(logged) != 1 || logged[0]["level"] != "WARN" || logged[0]["model_id"] != live.ModelID ||
		logged[0]["model_aggregate_sha256"] != live.ModelAggregateSHA256 || logged[0]["prompt_contract_id"] != live.PromptContractID {
		t.Fatalf("stale allowlist warnings=%v, want one naming %+v", logged, live)
	}

	configureStaleAllowlistTest(t, srv, registry.CacheRoutingOn, []registry.CacheRoutingArtifact{previous, live})
	if status := srv.ExactCacheStatusSnapshot(); status.ArtifactAllowlist.StaleModels != 0 || len(warnings()) != 1 {
		t.Fatalf("appended tuple still reported: status=%+v warnings=%d", status.ArtifactAllowlist, len(warnings()))
	}

	configureStaleAllowlistTest(t, srv, registry.CacheRoutingOn, []registry.CacheRoutingArtifact{previous})
	srv.ExactCacheStatusSnapshot()
	if len(warnings()) != 2 {
		t.Fatalf("recurrence warnings=%d, want 2", len(warnings()))
	}
}

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.String()
}
