package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
	"time"
)

func TestQualifiedProfileBindsEffectiveMTPIdentity(t *testing.T) {
	p, profile := reviewedProfileFixture(t)
	zero := 0
	mtp := &protocol.ServingMTPIdentity{Enabled: true, ArtifactSHA256: strings.Repeat("e", 64), MaxDraftTokens: 4, FixedDraftTokens: &zero, MaxSpeculativeBatch: 2, VerificationMode: "automatic", MaxAutomaticRectangularTokens: 4096}
	profile.MTP = mtp
	if qualifiedPerformanceProfileLocked(p, "model") != nil {
		t.Fatal("plain target borrowed an MTP qualification")
	}
	ref := p.BackendCapacity.Slots[0].PerformanceProfile
	ref.MTP = mtp.Clone()
	if qualifiedPerformanceProfileLocked(p, "model") != profile {
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
			if qualifiedPerformanceProfileLocked(p, "model") != nil {
				t.Fatal("different effective runtime borrowed profile")
			}
		})
	}
	ref.MTP = mtp.Clone()
	profile.MTP = nil
	if qualifiedPerformanceProfileLocked(p, "model") != nil {
		t.Fatal("MTP runtime borrowed plain-target profile")
	}
}

func TestCalibratedSnapshotOwnsWireFields(t *testing.T) {
	now := time.Now()
	_, p, _, _ := calibratedCandidateFixture(t, now)
	source := &p.BackendCapacity.Slots[0]
	fixed := 0
	source.PerformanceProfile.MTP = &protocol.ServingMTPIdentity{FixedDraftTokens: &fixed}
	source.DeadlineProfile.MTP = &protocol.ServingMTPIdentity{FixedDraftTokens: &fixed}
	stripe, mixed := 4096, 256
	source.DeadlineProfile.SoloPrefillStripeTokens = &stripe
	source.DeadlineProfile.MixedPrefillTokenCap = &mixed
	var cloned protocol.BackendSlotCapacity
	cloneBackendSlot(&cloned, source)
	cloned.DeadlineWork.Known = false
	*cloned.PerformanceProfile.MTP.FixedDraftTokens = 1
	*cloned.DeadlineProfile.MTP.FixedDraftTokens = 2
	*cloned.DeadlineProfile.SoloPrefillStripeTokens = 1
	*cloned.DeadlineProfile.MixedPrefillTokenCap = 1
	if !source.DeadlineWork.Known || fixed != 0 || stripe != 4096 || mixed != 256 {
		t.Fatal("accepted capacity aliases mutable caller evidence")
	}
}

func TestContendedMeasurementFreshnessUsesSampleIdentity(t *testing.T) {
	now := time.Now()
	_, p, _, _ := calibratedCandidateFixture(t, now)
	original := p.firstContentMeasurements["model"].contendedObservedAfter
	later := now.Add(3 * time.Minute)
	p.reconcileFirstContentMeasurementsLocked(p.BackendCapacity, later)
	if !p.firstContentMeasurements["model"].contendedObservedAfter.Equal(original) {
		t.Fatal("heartbeat rejuvenated unchanged contended observation")
	}
	sample := p.BackendCapacity.Slots[0].PerformanceMeasurements.ContendedPrefill
	sample.SampleCount++
	p.reconcileFirstContentMeasurementsLocked(p.BackendCapacity, later)
	if !p.firstContentMeasurements["model"].contendedObservedAfter.Equal(later.Add(-time.Second)) {
		t.Fatal("new contended observation failed to refresh")
	}
}
