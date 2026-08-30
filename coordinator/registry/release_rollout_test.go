package registry

import (
	"context"
	"crypto/elliptic"
	"encoding/base64"
	"errors"
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func rolloutRegistryTestIdentity(seed byte) string {
	scalar := make([]byte, 32)
	scalar[31] = seed
	x, y := elliptic.P256().ScalarBaseMult(scalar)
	return base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), x, y))
}

func authorizeRolloutTestProvider(provider *Provider, seed byte) {
	identity := rolloutRegistryTestIdentity(seed)
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: identity, SerialNumber: "serial",
	})
	provider.mu.Lock()
	provider.TrustLevel = TrustHardware
	provider.Attested = true
	provider.RolloutApprovalRequired = true
	provider.RolloutReleaseApproved = true
	provider.DeviceEvidence = DeviceEvidence{
		SEPublicKey: identity, Serial: "serial", VerifiedAt: time.Now(),
		ExpiresAt: time.Now().Add(time.Hour), EvidenceGeneration: 1,
	}
	provider.mu.Unlock()
}

func TestCanonicalRolloutIdentityNormalizesValidatedP256Bytes(t *testing.T) {
	identity := rolloutRegistryTestIdentity(9)
	alternate := identity[:8] + "\n" + identity[8:]
	canonical, ok := canonicalRolloutP256Identity(alternate)
	if !ok || canonical != identity {
		t.Fatalf("canonical identity = %q/%v, want %q", canonical, ok, identity)
	}
	if _, ok := canonicalRolloutP256Identity("not-a-p256-key"); ok {
		t.Fatal("invalid P-256 identity accepted")
	}
}
func TestReleaseCohortMembershipDeterministicNestedStages(t *testing.T) {
	stages := []store.RolloutStage{
		store.RolloutStage1, store.RolloutStage5, store.RolloutStage25,
		store.RolloutStage50, store.RolloutStage100,
	}
	counts := make([]int, len(stages))
	for i := range 10_000 {
		identity := "canonical-se-identity-" + strconv.Itoa(i)
		previous := false
		for stageIndex, stage := range stages {
			first := ReleaseCohortMember(identity, stage, nil)
			second := ReleaseCohortMember(identity, stage, nil)
			if first != second {
				t.Fatalf("non-deterministic membership for %q at %q", identity, stage)
			}
			if previous && !first {
				t.Fatalf("cohort shrank for %q at %q", identity, stage)
			}
			if first {
				counts[stageIndex]++
			}
			previous = first
		}
	}
	for i, want := range []int{100, 500, 2500, 5000, 10000} {
		if delta := counts[i] - want; delta < -150 || delta > 150 {
			t.Fatalf("stage %s membership count = %d, unexpectedly far from %d", stages[i], counts[i], want)
		}
	}
}

func TestReleaseCohortCanaryAndPreviousOutsideCohort(t *testing.T) {
	policy := store.ReleaseRolloutPolicy{
		TargetVersion: "2.0.0", PreviousVersion: "1.9.0", Stage: store.RolloutStageCanary,
		CanarySEIdentities: []string{"se-canary"},
	}
	if !ReleaseCohortMember("se-canary", policy.Stage, policy.CanarySEIdentities) ||
		ReleaseCohortMember("provider-session-se-canary", policy.Stage, policy.CanarySEIdentities) {
		t.Fatal("canary membership did not use exact canonical identity")
	}
	if version, command := ApprovedReleaseVersion(policy, "se-outside", "1.9.0"); version != "1.9.0" || command {
		t.Fatalf("outside previous approval = %q/%v", version, command)
	}
	if version, command := ApprovedReleaseVersion(policy, "se-outside", "1.8.0"); version != "" || command {
		t.Fatalf("outside stale release must receive no target: %q/%v", version, command)
	}
	if version, command := ApprovedReleaseVersion(policy, "se-canary", "2.1.0"); version != "" || command {
		t.Fatalf("newer provider must never receive downgrade: %q/%v", version, command)
	}
}

func TestApprovedReleaseVersionUsesSemVerPrereleaseOrdering(t *testing.T) {
	finalPolicy := store.ReleaseRolloutPolicy{
		TargetVersion: "2.0.1", Stage: store.RolloutStage100,
	}
	if version, command := ApprovedReleaseVersion(finalPolicy, "identity", "2.0.1-rc.1"); version != "2.0.1" || !command {
		t.Fatalf("RC to final approval = %q/%v", version, command)
	}
	rcPolicy := store.ReleaseRolloutPolicy{
		TargetVersion: "2.0.1-rc.1", Stage: store.RolloutStage100,
	}
	if version, command := ApprovedReleaseVersion(rcPolicy, "identity", "2.0.1"); version != "" || command {
		t.Fatalf("final to RC downgrade approved = %q/%v", version, command)
	}
}

func TestUpdateLifecycleOrderingRecertificationGenerationAndWarmIntent(t *testing.T) {
	state := protocol.UpdateLifecycleServing
	provider := &Provider{
		Version: "1.0.0", UpdateLifecycleReported: true,
		UpdateLifecycleState: state,
		ApplicationEvidence:  ApplicationEvidence{Version: "1.0.0", EvidenceGeneration: 7},
	}
	if !provider.BeginReleaseUpdate("1.1.0", 42) {
		t.Fatal("BeginReleaseUpdate rejected")
	}
	warm := protocol.WarmIntent{
		ModelID: "model", ModelHash: "hash", SlotID: "slot-1",
		KVBackend: "paged", KVQuantization: "q8", MTPModelID: "mtp",
		DesiredGeneration: 42,
	}
	installing := protocol.UpdateLifecycleInstalling
	if provider.ApplyUpdateLifecycleReport(&installing, &warm) {
		t.Fatal("lifecycle skipped draining")
	}
	draining := protocol.UpdateLifecycleDrainingForUpdate
	if !provider.ApplyUpdateLifecycleReport(&draining, &warm) || !reflect.DeepEqual(provider.WarmIntent, warm) {
		t.Fatalf("draining/warm intent not preserved exactly: %+v", provider.WarmIntent)
	}
	staleWarm := warm
	staleWarm.DesiredGeneration = 41
	if provider.ApplyUpdateLifecycleReport(&installing, &staleWarm) {
		t.Fatal("stale desired generation advanced lifecycle")
	}
	if !provider.ApplyUpdateLifecycleReport(&installing, &warm) {
		t.Fatal("installing rejected")
	}
	reconnecting := protocol.UpdateLifecycleReconnecting
	applicationVerifying := protocol.UpdateLifecycleApplicationVerifying
	modelReloading := protocol.UpdateLifecycleModelReloading
	ready := protocol.UpdateLifecycleReady
	if !provider.ApplyUpdateLifecycleReport(&reconnecting, &warm) ||
		!provider.ApplyUpdateLifecycleReport(&applicationVerifying, &warm) {
		t.Fatal("reconnect/application verification transition rejected")
	}
	if provider.ApplyUpdateLifecycleReport(&modelReloading, &warm) {
		t.Fatal("model reload accepted without recertified application evidence")
	}
	provider.mu.Lock()
	provider.Version = "1.1.0"
	provider.ApplicationEvidence = ApplicationEvidence{Version: "1.1.0", EvidenceGeneration: 8}
	provider.mu.Unlock()
	if !provider.ApplyUpdateLifecycleReport(&modelReloading, &warm) ||
		!provider.ApplyUpdateLifecycleReport(&ready, &warm) {
		t.Fatal("recertified terminal lifecycle rejected")
	}
	provider.mu.Lock()
	isReady := provider.ReleaseUpdateReadyLocked()
	provider.mu.Unlock()
	if !isReady {
		t.Fatal("provider did not become ready after ordered recertified lifecycle")
	}
}

func TestBeginReleaseUpdateStableTargetGenerationAuthority(t *testing.T) {
	state := protocol.UpdateLifecycleReady
	provider := &Provider{
		Version: "2.0.0", UpdateLifecycleReported: true,
		UpdateLifecycleState: state, UpdateTargetVersion: "2.0.0",
		UpdateDesiredGeneration: 9, updateLifecycleStep: lifecycleStep(state),
		ApplicationEvidence:           ApplicationEvidence{Version: "2.0.0", EvidenceGeneration: 12},
		updateApplicationEvidenceBase: 11,
	}
	if !provider.BeginReleaseUpdate("2.0.0", 9) {
		t.Fatal("same target/generation was not idempotent")
	}
	if provider.UpdateLifecycleState != state ||
		provider.updateLifecycleStep != lifecycleStep(state) ||
		provider.updateApplicationEvidenceBase != 11 {
		t.Fatalf("idempotent bind reset lifecycle: %+v", provider)
	}
	if provider.BeginReleaseUpdate("2.1.0", 9) {
		t.Fatal("equal generation accepted conflicting target")
	}
	if provider.BeginReleaseUpdate("2.0.0", 10) ||
		provider.UpdateDesiredGeneration != 9 ||
		provider.UpdateLifecycleState != state {
		t.Fatal("higher generation for identical target did not fail closed")
	}
	if !provider.BeginReleaseUpdate("2.1.0", 10) ||
		provider.UpdateTargetVersion != "2.1.0" ||
		provider.UpdateDesiredGeneration != 10 {
		t.Fatal("newer generation for genuinely new target was rejected from ready")
	}
}

func TestBindProviderReleaseReconnectAfterPause(t *testing.T) {
	registry := New(testLogger())
	reconnecting := protocol.UpdateLifecycleReconnecting
	warm := &protocol.WarmIntent{DesiredGeneration: 14, ModelID: "model"}
	provider := registry.Register("paused-reconnect", nil, &protocol.RegisterMessage{
		Version: "3.0.0", UpdateLifecycleState: &reconnecting, WarmIntent: warm,
	})
	provider.Version = "3.0.0"
	authorizeRolloutTestProvider(provider, 3)
	if !registry.BindProviderReleaseReconnect(provider.ID, "3.0.0", 14) {
		t.Fatal("resume did not bind paused current-target reconnect")
	}
	if registry.BindProviderReleaseReconnect(provider.ID, "3.0.0", 15) {
		t.Fatal("paused reconnect accepted higher generation for same target")
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if provider.UpdateTargetVersion != "3.0.0" ||
		provider.UpdateDesiredGeneration != 14 ||
		provider.UpdateLifecycleState != protocol.UpdateLifecycleReconnecting {
		t.Fatalf("unexpected rebound state: target=%q generation=%d state=%q",
			provider.UpdateTargetVersion, provider.UpdateDesiredGeneration, provider.UpdateLifecycleState)
	}
}

func TestBindPausedReadyReconnectPreservesFreshRecertification(t *testing.T) {
	registry := New(testLogger())
	ready := protocol.UpdateLifecycleReady
	warm := &protocol.WarmIntent{DesiredGeneration: 15, ModelID: "model"}
	provider := registry.Register("paused-ready", nil, &protocol.RegisterMessage{
		Version: "3.1.0", UpdateLifecycleState: &ready, WarmIntent: warm,
	})
	authorizeRolloutTestProvider(provider, 4)
	provider.mu.Lock()
	provider.Version = "3.1.0"
	provider.ApplicationEvidence = ApplicationEvidence{
		Version: "3.1.0", EvidenceGeneration: 4,
	}
	provider.mu.Unlock()
	if !registry.BindProviderReleaseReconnect(provider.ID, "3.1.0", 15) {
		t.Fatal("paused ready reconnect did not bind")
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if !provider.ReleaseUpdateReadyLocked() ||
		provider.updateLifecycleStep != lifecycleStep(protocol.UpdateLifecycleReady) {
		t.Fatalf("paused ready progress was not restored: state=%q step=%d base=%d",
			provider.UpdateLifecycleState, provider.updateLifecycleStep,
			provider.updateApplicationEvidenceBase)
	}
}

func TestBindPausedModelReloadingReconnectCanAdvanceReady(t *testing.T) {
	registry := New(testLogger())
	reloading := protocol.UpdateLifecycleModelReloading
	warm := &protocol.WarmIntent{DesiredGeneration: 16, ModelID: "model"}
	provider := registry.Register("paused-reloading", nil, &protocol.RegisterMessage{
		Version: "3.2.0", UpdateLifecycleState: &reloading, WarmIntent: warm,
	})
	authorizeRolloutTestProvider(provider, 5)
	provider.mu.Lock()
	provider.Version = "3.2.0"
	provider.ApplicationEvidence = ApplicationEvidence{
		Version: "3.2.0", EvidenceGeneration: 6,
	}
	provider.mu.Unlock()
	if !registry.BindProviderReleaseReconnect(provider.ID, "3.2.0", 16) {
		t.Fatal("paused model-reloading reconnect did not bind")
	}
	ready := protocol.UpdateLifecycleReady
	if !provider.ApplyUpdateLifecycleReport(&ready, warm) {
		t.Fatal("rebound model-reloading state could not advance to ready")
	}
	provider.mu.Lock()
	defer provider.mu.Unlock()
	if !provider.ReleaseUpdateReadyLocked() {
		t.Fatal("rebound model-reloading provider did not become ready")
	}
}

func TestTargetEmptyReadyLifecycleRemainsCompatible(t *testing.T) {
	provider := &Provider{
		UpdateLifecycleReported: true,
		UpdateLifecycleState:    protocol.UpdateLifecycleReady,
	}
	provider.mu.Lock()
	ready := provider.ReleaseUpdateReadyLocked()
	provider.mu.Unlock()
	if !ready {
		t.Fatal("target-empty ready provider was stranded")
	}
}

func TestRoutingAllowsTargetEmptyReadyLifecycle(t *testing.T) {
	registry := New(testLogger())
	const model = "target-empty-ready-model"
	provider := registerProviderWithModel(registry, "target-empty-ready", model)
	makeProviderRoutable(provider)
	provider.mu.Lock()
	provider.UpdateLifecycleReported = true
	provider.UpdateLifecycleState = protocol.UpdateLifecycleReady
	provider.UpdateTargetVersion = ""
	provider.mu.Unlock()
	ids := registry.RoutableProviderIDsForBuild(model)
	if len(ids) != 1 || ids[0] != provider.ID {
		t.Fatalf("target-empty ready provider not routable: %v", ids)
	}
}

func TestRolloutHardwareSnapshotRequiresLiveMatchingDeviceLease(t *testing.T) {
	registry := New(testLogger())
	serving := protocol.UpdateLifecycleServing
	provider := registry.Register("hardware-lease", nil, &protocol.RegisterMessage{
		UpdateLifecycleState: &serving,
	})
	now := time.Now()
	identity := rolloutRegistryTestIdentity(1)
	provider.mu.Lock()
	provider.RolloutReleaseApproved = true
	provider.TrustLevel = TrustHardware
	provider.Attested = true
	provider.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: identity, SerialNumber: "serial",
	}

	provider.DeviceEvidence = DeviceEvidence{
		SEPublicKey: identity, Serial: "serial", VerifiedAt: now.Add(-time.Hour),
		ExpiresAt: now.Add(-time.Second), EvidenceGeneration: 1,
	}
	provider.mu.Unlock()
	if snapshots := registry.ReleaseRolloutProviderSnapshots(); snapshots[0].HardwareVerified {
		t.Fatal("expired hardware lease remained verified")
	}
	provider.mu.Lock()
	provider.DeviceEvidence.ExpiresAt = now.Add(time.Hour)
	provider.mu.Unlock()
	if snapshots := registry.ReleaseRolloutProviderSnapshots(); !snapshots[0].HardwareVerified {
		t.Fatal("live matching hardware lease was not verified")
	}
}
func TestReleaseUpdateWriteFailureRollsBackBindingForRetry(t *testing.T) {
	registry := New(testLogger())
	serving := protocol.UpdateLifecycleServing
	provider := registry.Register("write-retry", nil, &protocol.RegisterMessage{
		Version: "1.0.0", UpdateLifecycleState: &serving,
	})
	provider.mu.Lock()
	provider.Version = "1.0.0"
	provider.mu.Unlock()
	authorizeRolloutTestProvider(provider, 7)
	attempts := 0
	registry.SetReleaseUpdateSenderForTesting(func(context.Context, string, protocol.ReleaseUpdateMessage) error {
		attempts++
		if attempts == 1 {
			return errors.New("write failed")
		}
		return nil
	})
	release := store.Release{Version: "2.0.0", Platform: "macos-arm64"}
	if err := registry.SendReleaseUpdate(provider.ID, release, 2); err == nil {
		t.Fatal("first write unexpectedly succeeded")
	}
	provider.mu.Lock()
	if provider.UpdateTargetVersion != "" || provider.UpdateDesiredGeneration != 0 ||
		provider.UpdateLifecycleState != protocol.UpdateLifecycleServing {
		t.Fatalf("failed write retained binding: target=%q generation=%d state=%q",
			provider.UpdateTargetVersion, provider.UpdateDesiredGeneration,
			provider.UpdateLifecycleState)
	}
	provider.mu.Unlock()
	if err := registry.SendReleaseUpdate(provider.ID, release, 2); err != nil {
		t.Fatalf("idempotent retry failed: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("write attempts=%d", attempts)
	}
}

func TestEmptyWarmIntentCanAdvanceBoundLifecycle(t *testing.T) {
	serving := protocol.UpdateLifecycleServing
	provider := &Provider{
		Version: "1.0.0", UpdateLifecycleReported: true,
		UpdateLifecycleState: serving,
	}
	if !provider.BeginReleaseUpdate("2.0.0", 3) {
		t.Fatal("begin update failed")
	}
	draining := protocol.UpdateLifecycleDrainingForUpdate
	installing := protocol.UpdateLifecycleInstalling
	if !provider.ApplyUpdateLifecycleReport(&draining, nil) ||
		!provider.ApplyUpdateLifecycleReport(&installing, nil) {
		t.Fatal("empty warm intent blocked ordered lifecycle")
	}
	if provider.WarmIntent != (protocol.WarmIntent{}) {
		t.Fatalf("empty warm intent was not preserved: %+v", provider.WarmIntent)
	}
}
