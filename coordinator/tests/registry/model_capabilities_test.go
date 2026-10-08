package registry_test

import (
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestHasProviderForModel(t *testing.T) {
	reg := production.New(testLogger())
	if reg.HasProviderForModel(gemmaBuild) || reg.HasProviderAdvertisingToolConstraint(gemmaBuild) {
		t.Fatal("empty fleet advertised model capabilities")
	}
	makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80, qwenBuild)
	if !reg.HasProviderForModel(gemmaBuild) || !reg.HasProviderForModel(qwenBuild) {
		t.Fatal("mixed provider must advertise each model independently")
	}
	if reg.HasProviderForModel("absent-model") || reg.HasProviderAdvertisingToolConstraint(gemmaBuild) {
		t.Fatal("fleet advertised an absent model or unreported tool constraint")
	}
}

func TestModelCapabilityQueriesPreserveGates(t *testing.T) {
	for _, tc := range []struct {
		name     string
		mutate   func(*production.Registry, *production.Provider)
		serial   string
		provider bool
		tools    bool
	}{
		{name: "mixed_catalog", provider: true, tools: true},
		{name: "matching_serial", serial: "serial", provider: true, tools: true},
		{name: "other_serial", serial: "other"},
		{name: "offline", mutate: func(_ *production.Registry, p *production.Provider) { p.Status = production.StatusOffline }},
		{name: "untrusted", mutate: func(_ *production.Registry, p *production.Provider) { p.Status = production.StatusUntrusted }},
		{name: "off_catalog", mutate: func(r *production.Registry, _ *production.Provider) {
			r.SetModelCatalog([]production.CatalogEntry{{ID: qwenBuild}})
		}},
		{name: "hash_unreported", provider: true, tools: true, mutate: func(r *production.Registry, _ *production.Provider) {
			r.SetModelCatalog([]production.CatalogEntry{{ID: gemmaBuild, WeightHash: "expected"}})
		}},
		{name: "hash_mismatch", mutate: func(r *production.Registry, p *production.Provider) {
			r.SetModelCatalog([]production.CatalogEntry{{ID: gemmaBuild, WeightHash: "expected"}})
			r.UpdateModelWeightHashes(p.ID, map[string]string{gemmaBuild: "mismatched"})
		}},
		{name: "missing_tool_model", provider: true, mutate: func(_ *production.Registry, p *production.Provider) {
			p.ToolConstraintModels = map[string]struct{}{qwenBuild: {}}
		}},
		{name: "unsupported_tool_protocol", provider: true, mutate: func(_ *production.Registry, p *production.Provider) {
			p.ToolConstraintProtocol = 0
		}},
		{name: "transient_routing_unavailable", provider: true, tools: true, mutate: func(_ *production.Registry, p *production.Provider) {
			p.TrustLevel = production.TrustNone
			p.RuntimeVerified = false
			p.LastChallengeVerified = time.Time{}
			p.BackendCapacity.Slots[0].State = "crashed"
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reg := production.New(testLogger())
			provider := makeSchedulerProvider(t, reg, "mixed", gemmaBuild, 80, qwenBuild)
			setSchedulerProviderSerial(provider, "serial")
			provider.ToolConstraintProtocol = production.ToolConstraintProtocolV1
			provider.ToolConstraintModels = map[string]struct{}{gemmaBuild: {}}
			if tc.mutate != nil {
				tc.mutate(reg, provider)
			}
			var allowed []string
			if tc.serial != "" {
				allowed = []string{tc.serial}
			}
			if got := reg.HasProviderForModel(gemmaBuild, allowed...); got != tc.provider {
				t.Errorf("HasProviderForModel=%v, want %v", got, tc.provider)
			}
			if got := reg.HasProviderAdvertisingToolConstraint(gemmaBuild, allowed...); got != tc.tools {
				t.Errorf("HasProviderAdvertisingToolConstraint=%v, want %v", got, tc.tools)
			}
		})
	}
}
