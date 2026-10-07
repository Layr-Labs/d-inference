package inference_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestExactCacheDatadogGaugesAreAggregateAndPrivacySafe(t *testing.T) {
	srv, _ := testServer(t)
	reg := srv.registry
	srv.SetPromptSupervisor(promptcontract.NewSupervisor(promptcontract.SupervisorConfig{
		Enabled: true,
	}))
	reg.Register("private-provider-v0", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "private-model-v0"}},
	})
	v1Statuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "private-model-v1", Backend: "paged", ReplayStrategy: "none",
		State: "disabled", Reason: "paged_hybrid_unsupported",
	}}
	reg.Register("private-provider-v1", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 1,
		Models:              []protocol.ModelInfo{{ID: "private-model-v1"}},
		PrefixCacheStatuses: &v1Statuses,
	})
	v2Statuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "private-model-v2", Backend: "contiguous", ReplayStrategy: "frozen_full",
		State: "ready", Reason: "ready",
	}}
	v2 := reg.Register("private-provider-v2", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol: 2,
		Models: []protocol.ModelInfo{{
			ID: "private-model-v2", WeightHash: strings.Repeat("a", 64),
		}},
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{{
			ModelID: "private-model-v2", ModelAggregateHash: strings.Repeat("a", 64),
			PromptContractID: strings.Repeat("b", 64),
			BlockHashVersion: promptcontract.BlockHashVersion,
			BlockSize:        promptcontract.BlockSize,
			CacheEpoch:       "11111111-1111-1111-1111-111111111111",
			Enabled:          true, Ready: true,
		}},
		PrefixCacheStatuses: &v2Statuses,
	})
	if v2 == nil {
		t.Fatal("register v2 provider")
	}
	memory := cacheEligibilityV2Capability("private-model-memory")
	reg.Register("private-provider-memory", nil, &protocol.RegisterMessage{
		PrefixCacheProtocol:     2,
		Models:                  []protocol.ModelInfo{{ID: memory.ModelID, WeightHash: memory.ModelAggregateHash}},
		PrefixCacheMemoryModels: []protocol.PrefixCacheV2Capability{memory},
	})

	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.observation.SetDatadog(ddClient)
	srv.EmitExactCacheDDGauges()
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	for _, metric := range []string{
		"exact_cache.artifact_allowlist.configured",
		"exact_cache.artifact_allowlist.count",
		"exact_cache.artifact_allowlist.stale_models",
		"exact_cache.memory_ready_models",
		"exact_cache.eligibility_state",
		"exact_cache.eligibility_reason",
		"exact_cache.eligibility_backend",
		"exact_cache.eligibility_strategy",
		"exact_cache.holder_removed",
		"exact_cache.donation_outcome",
		"exact_cache.fence",
		"exact_cache.fenced_capabilities",
		"exact_cache.demand_entries",
		"exact_cache.demand_cap_evictions",
	} {
		if !hasMetric(packets, metric) {
			t.Fatalf("missing Datadog gauge %q in %v", metric, packets)
		}
	}
	encodedPackets := strings.Join(packets, "\n")
	for _, sensitive := range []string{
		"private-provider", "private-model", strings.Repeat("a", 64),
		strings.Repeat("b", 64), "11111111-1111-1111-1111-111111111111",
	} {
		if strings.Contains(encodedPackets, sensitive) {
			t.Fatalf("Datadog cache gauges leaked %q: %s", sensitive, encodedPackets)
		}
	}
}
