package registry_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/serviceretirement"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDeadlineProfileRequiresExactSchedulerAndArtifactIdentity(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*production.Provider, *deadline.Profile)
	}{
		{"unknown profile", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.ID = "unknown"
		}},
		{"runtime", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.RuntimeRevision = "old"
		}},
		{"configured context", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.ConfiguredContextTokens--
		}},
		{"scheduler width", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.EffectiveMaxConcurrency--
		}},
		{"chunk size", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.PrefillChunkSize++
		}},
		{"partial prefill policy", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MaxConcurrentPartialPrefills++
		}},
		{"mixed cap presence", func(p *production.Provider, _ *deadline.Profile) {
			v := 256
			p.BackendCapacity.Slots[0].DeadlineProfile.MixedPrefillTokenCap = &v
		}},
		{"solo stripe presence", func(p *production.Provider, _ *deadline.Profile) {
			v := 4096
			p.BackendCapacity.Slots[0].DeadlineProfile.SoloPrefillStripeTokens = &v
		}},
		{"target artifact", func(p *production.Provider, _ *deadline.Profile) { p.Models[0].WeightHash = strings.Repeat("f", 64) }},
		{"provider version", func(p *production.Provider, _ *deadline.Profile) { p.Version = "next" }},
		{"hardware", func(p *production.Provider, _ *deadline.Profile) { p.Hardware.GPUCores-- }},
		{"thermal posture", func(p *production.Provider, _ *deadline.Profile) { p.SystemMetrics.ThermalState = "serious" }},
		{"MTP configuration", func(p *production.Provider, _ *deadline.Profile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MTP = &protocol.ServingMTPIdentity{Enabled: true,
				ArtifactSHA256: strings.Repeat("e", 64), MaxDraftTokens: 4, MaxSpeculativeBatch: 2, VerificationMode: "automatic"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newCalibrationPolicyFixture(t, time.Now())
			if f.catalog.Qualified(f.identity(), "model") != f.profile {
				t.Fatal("exact independent deadline evidence did not resolve")
			}
			tc.change(f.provider, f.profile)
			if f.catalog.Qualified(f.identity(), "model") != nil {
				t.Fatal("changed identity borrowed deadline cells")
			}
		})
	}
}

func TestDeadlineOnlyProfileDoesNotGrantServingPolicy(t *testing.T) {
	now := time.Now()
	policy, retirement := &quality.Policy{}, &serviceretirement.Ledger{}
	f := newCalibrationPolicyFixtureWithDependencies(t, now, func(deps *production.Dependencies) {
		deps.QualityPolicy = policy
		deps.ServiceRetirements = func(string) *serviceretirement.Ledger { return retirement }
	})
	r, p, profile, pr := f.registry, f.provider, f.profile, f.request
	slot := &p.BackendCapacity.Slots[0]
	slot.PerformanceProfile = nil
	profile.ConfiguredContextTokens, slot.DeadlineProfile.ConfiguredContextTokens = 262144, 262144
	profile.EffectiveMaxConcurrency, slot.DeadlineProfile.EffectiveMaxConcurrency, slot.MaxConcurrency = 8, 8, 8
	for i := range profile.DeadlineCalibration.Cells {
		profile.DeadlineCalibration.Cells[i].PromptTokensMax = 4096
		profile.DeadlineCalibration.Cells[i].ContextTokensMax = 4096
		profile.DeadlineCalibration.Cells[i].MaxActiveRequests = min(profile.DeadlineCalibration.Cells[i].MaxActiveRequests, profile.EffectiveMaxConcurrency)
	}
	serving := func() *performance.Profile {
		return f.serving.Qualified(performance.Identity{Version: p.Version, Hardware: p.Hardware, Models: p.Models,
			Capacity: p.BackendCapacity, ThermalState: p.SystemMetrics.ThermalState}, "model")
	}
	cap := func() int {
		base := quality.ConcurrencyLimit(p.BackendCapacity, p.Hardware, "model", production.DefaultMaxConcurrent)
		return policy.Cap("model", base, quality.Rate{TPS: 100, PerModel: true}, p.DecodeTPS > 0, false, warmplan.DecodeLoadFactor, serving())
	}
	ref := slot.DeadlineProfile
	slot.DeadlineProfile = nil
	baselineCap := cap()
	slot.DeadlineProfile = ref
	pr.RequestedMaxTokens = 32000 // Memory reserves this; the deadline prices only early output.
	c := f.evaluate(pr, now).Estimate
	if c.PredictionSource != "qualified_calibration" || c.Status != forecast.Feasible || serving() != nil {
		t.Fatalf("narrow deadline evidence required a universal serving curve: %+v", c)
	}
	if got := cap(); got != baselineCap {
		t.Fatalf("deadline evidence changed concurrency: %d -> %d", baselineCap, got)
	}
	encoded, err := json.Marshal(profile)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &raw); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"batch_curve", "max_concurrency", "whole_mac_concurrency", "context_tokens_max"} {
		if _, exists := raw[field]; exists {
			t.Fatalf("deadline-only record includes serving authority %q", field)
		}
	}
	// The runtime's large configured ceiling does not qualify an existing long
	// context. Its full retained work must still fit a measured cell domain.
	idleSlot := *slot
	slot.NumRunning = 1
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true,
		PrefillTokens: 1000, DecodeTokens: 7192, RequestCount: 1, ContextTokensMax: 8192, ServiceFraction: 1.0 / 24}
	*p.BackendCapacity.WholeMacServiceUsed = 1.0 / 24
	if c = f.evaluate(pr, now).Estimate; f.evidence(pr, now).Calibration.WorkKnown || c.PredictionSource != "" {
		t.Fatal("configured context was treated as a measured competing-work envelope")
	}

	// Observe the charge captured by the real pending/handoff/retirement path
	// after the forecast checks, so terminal activity cannot alter their clocks.
	*slot = idleSlot
	*p.BackendCapacity.WholeMacServiceUsed = 0
	capacity := p.BackendCapacitySnapshot()
	capacity.WholeMacServiceRetirementProtocol = 1
	if !r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity, SystemMetrics: p.SystemMetrics}) {
		t.Fatal("retirement capability heartbeat rejected")
	}
	slot = &p.BackendCapacity.Slots[0]
	charge := func() float64 {
		t.Helper()
		pending := &production.PendingRequest{RequestID: "serving-charge", Model: "model", ProviderID: p.ID}
		p.AddPending(pending)
		if err := p.NewInferenceHandoff(pending).Authorize(); err != nil {
			t.Fatal(err)
		}
		p.RemovePending(pending.RequestID)
		got := retirement.Account(nil).UnreportedCharge
		if !r.ReleaseServiceReservation(p, pending.ServiceReservationID()) {
			t.Fatal("charge observation did not release reservation")
		}
		return got
	}
	slot.DeadlineProfile = nil
	baselineCharge := charge()
	slot.DeadlineProfile = ref
	if charge() != baselineCharge || baselineCharge != 1.0/24 {
		t.Fatal("deadline evidence changed whole-Mac service allowance")
	}
}
