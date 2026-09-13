package api

import (
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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
			srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
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
			gauges := srv.metrics.Snapshot().Gauges
			if gauges["exact_cache_artifact_allowlist_configured"] != boolGauge(tc.configured) ||
				gauges["exact_cache_artifact_allowlist_count"] != float64(len(tc.artifacts)) {
				t.Fatalf("artifact gauges=%v", gauges)
			}
		})
	}
}
