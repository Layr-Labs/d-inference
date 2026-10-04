package registry_test

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func reviewedProfileEvidence(t *testing.T) (performance.Identity, *performance.Profile, *performance.Catalog) {
	t.Helper()
	profile := &performance.Profile{
		ID: "test-only-ultra", ModelID: "model", ArtifactSHA256: strings.Repeat("a", 64),
		ProviderVersion: "test", RuntimeRevision: performance.RuntimeRevision,
		KVBackend: "paged", ChipName: "Apple M5 Ultra", GPUCores: 80, MemoryGB: 192,
		ContextTokensMax: 32768, MaxConcurrency: 16, WholeMacConcurrency: 16,
		QualificationReportSHA256: strings.Repeat("b", 64),
		BatchCurve: []performance.BatchPoint{
			{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
			{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 6000, FirstContentP95MS: 2800},
		},
	}
	backend := "paged"
	identity := performance.Identity{
		Version: "test", Hardware: protocol.Hardware{ChipName: profile.ChipName, GPUCores: 80, MemoryGB: 192},
		Models: []protocol.ModelInfo{{ID: "model", WeightHash: profile.ArtifactSHA256}},
		Capacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
			Model: "model", MaxConcurrency: 16, ActiveTokenBudgetMax: 100000,
			KVBackend: &backend, PerformanceProfile: &protocol.ServingPerformanceProfileReference{
				ID: profile.ID, RuntimeRevision: profile.RuntimeRevision, ContextTokens: 32768},
		}}},
	}
	return identity, profile, performance.NewCatalog(profile)
}

func TestQualifiedPerformanceProfileExactIdentityAndCap(t *testing.T) {
	identity, profile, catalog := reviewedProfileEvidence(t)
	policy := quality.New(quality.Config{Enabled: true, FloorTPS: 30, Fallback: 1})
	if got := catalog.Qualified(identity, "model"); got != profile {
		t.Fatal("exact reviewed identity did not resolve")
	}
	cap := func() int {
		base := quality.ConcurrencyLimit(identity.Capacity, identity.Hardware, "model", 1)
		return policy.Cap("model", base, quality.Rate{TPS: 35, PerModel: true}, false, false, .39, catalog.Qualified(identity, "model"))
	}
	if got := cap(); got != 16 {
		t.Fatalf("qualified curve replaced by legacy M4 model: got %d", got)
	}
	identity.Capacity.Slots[0].MaxConcurrency = 2
	if got := cap(); got != 2 {
		t.Fatalf("operator cap lost: %d", got)
	}
	identity.Capacity.Slots[0].PerformanceProfile.ContextTokens++
	if catalog.Qualified(identity, "model") != nil {
		t.Fatal("profile borrowed beyond context range")
	}
	identity.Capacity.Slots[0].PerformanceProfile.ContextTokens--
	identity.Models[0].WeightHash = strings.Repeat("c", 64)
	if catalog.Qualified(identity, "model") != nil {
		t.Fatal("profile borrowed across artifacts")
	}
	identity.Models[0].WeightHash = profile.ArtifactSHA256
	identity.Hardware.GPUCores = 64
	if catalog.Qualified(identity, "model") != nil {
		t.Fatal("profile borrowed across GPU bins")
	}
	identity.Hardware.GPUCores = 80
	identity.Version = "next-release"
	if catalog.Qualified(identity, "model") != nil {
		t.Fatal("profile borrowed across runtime versions")
	}
}

func TestQualifiedProfileBindsEffectiveMTPIdentity(t *testing.T) {
	identity, profile, catalog := reviewedProfileEvidence(t)
	zero := 0
	mtp := &protocol.ServingMTPIdentity{Enabled: true, ArtifactSHA256: strings.Repeat("e", 64), MaxDraftTokens: 4, FixedDraftTokens: &zero, MaxSpeculativeBatch: 2, VerificationMode: "automatic", MaxAutomaticRectangularTokens: 4096}
	profile.MTP = mtp
	if catalog.Qualified(identity, "model") != nil {
		t.Fatal("plain target borrowed an MTP qualification")
	}
	ref := identity.Capacity.Slots[0].PerformanceProfile
	ref.MTP = mtp.Clone()
	if catalog.Qualified(identity, "model") != profile {
		t.Fatal("exact effective MTP identity rejected")
	}
	for _, tc := range []struct {
		name   string
		change func(*protocol.ServingMTPIdentity)
	}{
		{"assistant artifact", func(m *protocol.ServingMTPIdentity) { m.ArtifactSHA256 = strings.Repeat("f", 64) }},
		{"enabled", func(m *protocol.ServingMTPIdentity) { m.Enabled = false }},
		{"draft policy", func(m *protocol.ServingMTPIdentity) { m.FixedDraftTokens = nil }},
		{"batch", func(m *protocol.ServingMTPIdentity) { m.MaxSpeculativeBatch++ }},
		{"verification", func(m *protocol.ServingMTPIdentity) { m.VerificationMode = "serial_target" }},
		{"rectangular limit", func(m *protocol.ServingMTPIdentity) { m.MaxAutomaticRectangularTokens++ }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ref.MTP = mtp.Clone()
			tc.change(ref.MTP)
			if catalog.Qualified(identity, "model") != nil {
				t.Fatal("different effective runtime borrowed profile")
			}
		})
	}
	ref.MTP = mtp.Clone()
	profile.MTP = nil
	if catalog.Qualified(identity, "model") != nil {
		t.Fatal("MTP runtime borrowed plain-target profile")
	}
}

func TestPerformanceProfileCapacityClonesDoNotAliasLiveAdmission(t *testing.T) {
	identity, _, _ := reviewedProfileEvidence(t)
	used := 0.5
	identity.Capacity.WholeMacServiceUsed = &used
	var capacity protocol.BackendCapacity
	capacityvalue.CloneBackendCapacityFields(&capacity, identity.Capacity)
	var slot protocol.BackendSlotCapacity
	capacityvalue.CloneBackendSlot(&slot, &identity.Capacity.Slots[0])
	*capacity.WholeMacServiceUsed = 0
	slot.PerformanceProfile.ContextTokens = 1
	if *identity.Capacity.WholeMacServiceUsed != 0.5 {
		t.Fatal("snapshot changed live service allowance")
	}
	if identity.Capacity.Slots[0].PerformanceProfile.ContextTokens != 32768 {
		t.Fatal("snapshot changed live profile identity")
	}
}
