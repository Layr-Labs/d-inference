package registry

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestDeadlineProfileRequiresExactSchedulerAndArtifactIdentity(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*Provider, *deadlinePerformanceProfile)
	}{
		{"unknown profile", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.ID = "unknown"
		}},
		{"runtime", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.RuntimeRevision = "old"
		}},
		{"configured context", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.ConfiguredContextTokens--
		}},
		{"scheduler width", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.EffectiveMaxConcurrency--
		}},
		{"chunk size", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.PrefillChunkSize++
		}},
		{"partial prefill policy", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MaxConcurrentPartialPrefills++
		}},
		{"mixed cap presence", func(p *Provider, _ *deadlinePerformanceProfile) {
			v := 256
			p.BackendCapacity.Slots[0].DeadlineProfile.MixedPrefillTokenCap = &v
		}},
		{"solo stripe presence", func(p *Provider, _ *deadlinePerformanceProfile) {
			v := 4096
			p.BackendCapacity.Slots[0].DeadlineProfile.SoloPrefillStripeTokens = &v
		}},
		{"target artifact", func(p *Provider, _ *deadlinePerformanceProfile) { p.Models[0].WeightHash = strings.Repeat("f", 64) }},
		{"provider version", func(p *Provider, _ *deadlinePerformanceProfile) { p.Version = "next" }},
		{"hardware", func(p *Provider, _ *deadlinePerformanceProfile) { p.Hardware.GPUCores-- }},
		{"thermal posture", func(p *Provider, _ *deadlinePerformanceProfile) { p.SystemMetrics.ThermalState = "serious" }},
		{"MTP configuration", func(p *Provider, _ *deadlinePerformanceProfile) {
			p.BackendCapacity.Slots[0].DeadlineProfile.MTP = &protocol.ServingMTPIdentity{Enabled: true,
				ArtifactSHA256: strings.Repeat("e", 64), MaxDraftTokens: 4, MaxSpeculativeBatch: 2, VerificationMode: "automatic"}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, p, profile, _ := calibratedCandidateFixture(t, time.Now())
			if qualifiedDeadlineProfileLocked(p, "model") != profile {
				t.Fatal("exact independent deadline evidence did not resolve")
			}
			tc.change(p, profile)
			if qualifiedDeadlineProfileLocked(p, "model") != nil {
				t.Fatal("changed identity borrowed deadline cells")
			}
		})
	}
}

func TestDeadlineOnlyProfileDoesNotGrantServingPolicy(t *testing.T) {
	now := time.Now()
	r, p, profile, pr := calibratedCandidateFixture(t, now)
	slot := &p.BackendCapacity.Slots[0]
	slot.PerformanceProfile = nil
	profile.ConfiguredContextTokens, slot.DeadlineProfile.ConfiguredContextTokens = 262144, 262144
	profile.EffectiveMaxConcurrency, slot.DeadlineProfile.EffectiveMaxConcurrency, slot.MaxConcurrency = 8, 8, 8
	for i := range profile.DeadlineCalibration.Cells {
		profile.DeadlineCalibration.Cells[i].PromptTokensMax = 4096
		profile.DeadlineCalibration.Cells[i].ContextTokensMax = 4096
		profile.DeadlineCalibration.Cells[i].MaxActiveRequests = min(profile.DeadlineCalibration.Cells[i].MaxActiveRequests, profile.EffectiveMaxConcurrency)
	}
	ref := slot.DeadlineProfile
	slot.DeadlineProfile = nil
	baselineCap := r.effectiveMaxConcurrencyForModelRateLocked(p, "model", soloModelTPS{tps: 100, perModel: true})
	baselineCharge := p.serviceChargeForModelLocked("model")
	slot.DeadlineProfile = ref
	pr.RequestedMaxTokens = 32000 // Memory reserves this; the deadline prices only early output.
	c := calibratedForecast(r, p, pr, now)
	if c.firstContent.PredictionSource != "qualified_calibration" || c.firstContent.Status != FirstContentFeasible || c.snapshot.performanceProfile != nil {
		t.Fatalf("narrow deadline evidence required a universal serving curve: %+v", c.firstContent)
	}
	if got := r.effectiveMaxConcurrencyForModelRateLocked(p, "model", soloModelTPS{tps: 100, perModel: true}); got != baselineCap {
		t.Fatalf("deadline evidence changed concurrency: %d -> %d", baselineCap, got)
	}
	if p.serviceChargeForModelLocked("model") != baselineCharge || baselineCharge != 1.0/24 {
		t.Fatal("deadline evidence changed whole-Mac service allowance")
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
	slot.NumRunning = 1
	slot.DeadlineWork = &protocol.DeadlineWork{Version: 1, Epoch: "epoch", Known: true,
		PrefillTokens: 1000, DecodeTokens: 7192, RequestCount: 1, ContextTokensMax: 8192, ServiceFraction: 1.0 / 24}
	*p.BackendCapacity.WholeMacServiceUsed = 1.0 / 24
	if c = calibratedForecast(r, p, pr, now); c.snapshot.calibratedWorkKnown || c.firstContent.PredictionSource != "" {
		t.Fatal("configured context was treated as a measured competing-work envelope")
	}
}
