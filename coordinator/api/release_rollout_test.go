package api

import (
	"context"
	"crypto/elliptic"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func healthyRolloutObservations() RolloutHealthObservations {
	return RolloutHealthObservations{
		HardwareVerification:    RolloutWindowObservation{Observations: 100, Ratio: 1},
		MDMSaturation:           RolloutWindowObservation{Observations: 100, Ratio: 0},
		ApplicationVerification: RolloutWindowObservation{Observations: 100, Ratio: 1},
		ReconnectCrash:          RolloutWindowObservation{Observations: 100, Ratio: 0},
		NetworkCapacity:         RolloutWindowObservation{Observations: 100, Ratio: 1},
		ModelCapacity:           RolloutWindowObservation{Observations: 100, Ratio: 1},
		Server5xx:               RolloutWindowObservation{Observations: 100, Ratio: 0},
		QueueTimeout:            RolloutWindowObservation{Observations: 100, Ratio: 0},
		ReconnectCohort:         100,
		TargetedCohort:          100,
	}
}

func TestEvaluateRolloutHealthEveryAutomaticPauseReason(t *testing.T) {
	thresholds := defaultRolloutHealthThresholds()
	cases := []struct {
		reason    string
		breakGate func(*RolloutHealthObservations)
	}{
		{RolloutPauseHardwareVerificationRatio, func(o *RolloutHealthObservations) { o.HardwareVerification.Ratio = 0 }},
		{RolloutPauseMDMSaturation, func(o *RolloutHealthObservations) { o.MDMSaturation.Ratio = 1 }},
		{RolloutPauseApplicationVerificationRatio, func(o *RolloutHealthObservations) { o.ApplicationVerification.Ratio = 0 }},
		{RolloutPauseReconnectCrashRate, func(o *RolloutHealthObservations) { o.ReconnectCrash.Ratio = 1 }},
		{RolloutPauseNetworkCapacityFloor, func(o *RolloutHealthObservations) { o.NetworkCapacity.Ratio = 0 }},
		{RolloutPauseModelCapacityFloor, func(o *RolloutHealthObservations) { o.ModelCapacity.Ratio = 0 }},
		{RolloutPauseServer5xxRate, func(o *RolloutHealthObservations) { o.Server5xx.Ratio = 1 }},
		{RolloutPauseQueueTimeoutRate, func(o *RolloutHealthObservations) { o.QueueTimeout.Ratio = 1 }},
	}
	for _, test := range cases {
		t.Run(test.reason, func(t *testing.T) {
			observations := healthyRolloutObservations()
			test.breakGate(&observations)
			evaluation := EvaluateRolloutHealth(nil, observations, thresholds)
			if evaluation.Healthy || evaluation.PauseReason != test.reason {
				t.Fatalf("evaluation = %+v", evaluation)
			}
		})
	}
}

func TestEvaluateRolloutHealthInsufficientAndExplicitPause(t *testing.T) {
	observations := healthyRolloutObservations()
	observations.QueueTimeout.Observations = 0
	evaluation := EvaluateRolloutHealth(nil, observations, defaultRolloutHealthThresholds())
	if evaluation.Sufficient || evaluation.Healthy || evaluation.PauseReason != "" {
		t.Fatalf("insufficient evaluation = %+v", evaluation)
	}
	policy := &store.ReleaseRolloutPolicy{Paused: true, PauseReason: "operator_change_window"}
	evaluation = EvaluateRolloutHealth(policy, healthyRolloutObservations(), defaultRolloutHealthThresholds())
	if evaluation.Healthy || evaluation.PauseReason != policy.PauseReason {
		t.Fatalf("explicit pause hidden: %+v", evaluation)
	}
}

func rolloutIdentityInBucketRange(t *testing.T, minimum, maximum uint64) string {
	t.Helper()
	for i := range 1_000_000 {
		scalar := make([]byte, 32)
		binary.BigEndian.PutUint64(scalar[24:], uint64(i+1))
		x, y := elliptic.P256().ScalarBaseMult(scalar)
		identity := base64.StdEncoding.EncodeToString(
			elliptic.Marshal(elliptic.P256(), x, y))
		digest := sha256.Sum256([]byte(identity))
		bucket := binary.BigEndian.Uint64(digest[:8]) % 10_000
		if bucket >= minimum && bucket <= maximum {
			return identity
		}
	}
	t.Fatalf("no deterministic identity in bucket range %d..%d", minimum, maximum)
	return ""
}

func seedHealthyLiveRolloutWindow(server *Server, now time.Time) {
	server.rolloutHealth.mu.Lock()
	defer server.rolloutHealth.mu.Unlock()
	server.rolloutHealth.hardwareVerification.reset()
	server.rolloutHealth.mdmSaturation.reset()
	server.rolloutHealth.applicationVerification.reset()
	server.rolloutHealth.reconnectCrash.reset()
	server.rolloutHealth.networkCapacity.reset()
	server.rolloutHealth.modelCapacity.reset()
	server.rolloutHealth.traffic = rolloutTrafficWindow{}
	minimum := defaultRolloutHealthThresholds().MinObservations
	for i := range minimum {
		at := now.Add(-time.Duration(minimum-1-i) * rolloutHealthBucketWidth)
		server.rolloutHealth.hardwareVerification.observeAggregate(at, 1)
		server.rolloutHealth.mdmSaturation.observeAggregate(at, 0)
		server.rolloutHealth.applicationVerification.observeAggregate(at, 1)
		server.rolloutHealth.reconnectCrash.observe(at, 0)
		server.rolloutHealth.networkCapacity.observeAggregate(at, 1)
		server.rolloutHealth.modelCapacity.observeAggregate(at, 1)
		server.rolloutHealth.traffic.bucket(at).admitted++
	}
}

func TestAdminRolloutE2EExactStagesCommandsAndPreviousAcceptance(t *testing.T) {
	t.Setenv("EIGENINFERENCE_ROLLOUT_MIN_OBSERVATIONS", "20")
	memory := store.NewMemory(store.Config{})
	created := time.Now().Add(-time.Minute)
	previous := &store.Release{
		Version: "1.0.0", Platform: defaultReleasePlatform, Backend: registry.BackendMLXSwift,
		BinaryHash: strings.Repeat("a", 64), BundleHash: strings.Repeat("b", 64),
		URL: "https://releases.example/1.0.0", CreatedAt: created,
	}
	target := &store.Release{
		Version: "2.0.0", Platform: defaultReleasePlatform, Backend: registry.BackendMLXSwift,
		BinaryHash: strings.Repeat("c", 64), BundleHash: strings.Repeat("d", 64),
		URL: "https://releases.example/2.0.0", CreatedAt: created.Add(time.Second),
		TemplateHashes: protocol.TemplateHashInferenceWorkerBinary + "=" + strings.Repeat("e", 64),
	}
	if err := memory.SetRelease(previous); err != nil {
		t.Fatal(err)
	}
	if err := memory.SetRelease(target); err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	server := NewServer(reg, memory, ServerConfig{AdminKey: "admin-key"}, logger)
	defer server.Close()

	canary := rolloutIdentityInBucketRange(t, 9_999, 9_999)
	stageIdentity := map[store.RolloutStage]string{
		store.RolloutStage1:   rolloutIdentityInBucketRange(t, 0, 99),
		store.RolloutStage5:   rolloutIdentityInBucketRange(t, 100, 499),
		store.RolloutStage25:  rolloutIdentityInBucketRange(t, 500, 2_499),
		store.RolloutStage50:  rolloutIdentityInBucketRange(t, 2_500, 4_999),
		store.RolloutStage100: rolloutIdentityInBucketRange(t, 5_000, 9_997),
	}
	identities := map[string]string{
		"canary": canary,
		"newer":  rolloutIdentityInBucketRange(t, 9_998, 9_998),
	}
	for stage, identity := range stageIdentity {
		identities[string(stage)] = identity
	}
	state := protocol.UpdateLifecycleServing
	for id, identity := range identities {
		version := previous.Version
		if id == "newer" {
			version = "3.0.0"
		}
		warm := &protocol.WarmIntent{DesiredGeneration: 1}
		provider := reg.Register("provider-"+id, nil, &protocol.RegisterMessage{
			Version: version, Backend: registry.BackendMLXSwift,
			UpdateLifecycleState: &state, WarmIntent: warm,
		})
		provider.Mu().Lock()
		provider.Version = version
		provider.Mu().Unlock()
		provider.SetAttestationResult(&attestation.VerificationResult{
			Valid: true, PublicKey: identity, SerialNumber: "serial-" + id,
		})
		provider.Mu().Lock()
		provider.TrustLevel = registry.TrustHardware
		provider.Attested = true
		provider.DeviceEvidence = registry.DeviceEvidence{
			SEPublicKey: identity, Serial: "serial-" + id,
			VerifiedAt: time.Now(), ExpiresAt: time.Now().Add(time.Hour),
			EvidenceGeneration: 1,
		}
		provider.Mu().Unlock()
	}

	commandCount := make(map[string]int)
	reg.SetReleaseUpdateSenderForTesting(func(_ context.Context, providerID string, message protocol.ReleaseUpdateMessage) error {
		if message.Version != target.Version || message.DesiredGeneration != 1 ||
			message.InferenceWorkerBinaryHash != strings.Repeat("e", 64) {
			t.Fatalf("unexpected command: %+v", message)
		}
		commandCount[providerID]++
		return nil
	})

	start := doReq(server, "POST", "/v1/admin/release-rollout/promote", "Bearer admin-key",
		fmt.Sprintf(`{"platform":"%s","target_version":"%s","canary_se_identities":[%q,%q],"expected_revision":0}`,
			defaultReleasePlatform, target.Version, canary, identities["newer"]))
	if start.Code != 200 {
		t.Fatalf("start status=%d body=%s", start.Code, start.Body.String())
	}
	if commandCount["provider-canary"] != 1 || commandCount["provider-newer"] != 0 {
		t.Fatalf("canary/no-downgrade commands = %+v", commandCount)
	}
	previousProvider := reg.GetProvider("provider-100")
	previousProvider.Mu().Lock()
	previousApproved := previousProvider.RolloutReleaseApproved
	previousProvider.Mu().Unlock()
	if !previousApproved {
		t.Fatal("previous release outside canary cohort was not approved")
	}

	policy, err := memory.GetReleaseRollout(t.Context(), defaultReleasePlatform)
	if err != nil {
		t.Fatal(err)
	}
	stages := []store.RolloutStage{
		store.RolloutStage1, store.RolloutStage5, store.RolloutStage25,
		store.RolloutStage50, store.RolloutStage100,
	}
	for _, stage := range stages {
		seedHealthyLiveRolloutWindow(server, time.Now().Add(-time.Second))
		response := doReq(server, "POST", "/v1/admin/release-rollout/promote", "Bearer admin-key",
			fmt.Sprintf(`{"platform":"%s","stage":%q,"expected_revision":%d}`,
				defaultReleasePlatform, stage, policy.Revision))
		if response.Code != 200 {
			t.Fatalf("promote %s status=%d body=%s", stage, response.Code, response.Body.String())
		}
		policy, err = memory.GetReleaseRollout(t.Context(), defaultReleasePlatform)
		if err != nil {
			t.Fatal(err)
		}
		if policy.Stage != stage {
			t.Fatalf("stage = %s, want %s", policy.Stage, stage)
		}
		newProviderID := "provider-" + string(stage)
		if commandCount[newProviderID] != 1 {
			t.Fatalf("new cohort %s command count=%d, all=%+v", stage, commandCount[newProviderID], commandCount)
		}
		if commandCount["provider-canary"] != 1 || commandCount["provider-newer"] != 0 {
			t.Fatalf("duplicate/downgrade command at %s: %+v", stage, commandCount)
		}
		if stage != store.RolloutStage100 {
			previousProvider.Mu().Lock()
			approved := previousProvider.RolloutReleaseApproved
			previousProvider.Mu().Unlock()
			if !approved {
				t.Fatalf("previous release outside %s cohort lost approval", stage)
			}
		}
	}
}

func TestRolloutTrafficCountsOnlyDispatchAdmittedContext(t *testing.T) {
	monitor := newRolloutHealthMonitor()
	now := time.Now()
	ctx := context.WithValue(context.Background(), rolloutHealthContextKey{}, &rolloutRequestHealthState{})
	monitor.recordDispatchAdmission(ctx, now)
	monitor.recordDispatchQueueTimeout(ctx, now)
	monitor.recordDispatchHTTPOutcome(ctx, 503, now)
	monitor.recordDispatchHTTPOutcome(context.Background(), 200, now)
	server5xx, queue := monitor.traffic.snapshot(now)
	if server5xx.Observations != 1 || server5xx.Ratio != 1 ||
		queue.Observations != 1 || queue.Ratio != 1 {
		t.Fatalf("traffic windows = 5xx:%+v queue:%+v", server5xx, queue)
	}
}

func TestReconnectObservationFloorScalesToCanary(t *testing.T) {
	observations := healthyRolloutObservations()
	observations.TargetedCohort = 1
	observations.ReconnectCrash = RolloutWindowObservation{Observations: 1, Ratio: 0}
	observations.ReconnectCohort = 1
	evaluation := EvaluateRolloutHealth(nil, observations, defaultRolloutHealthThresholds())
	if !evaluation.Sufficient || !evaluation.Healthy {
		t.Fatalf("one-provider canary remained insufficient: %+v", evaluation)
	}
}

func TestFreshCurrentTargetServingRemainsApprovedAcrossReconcile(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	target := &store.Release{Version: "4.0.0", Platform: defaultReleasePlatform}
	if err := memory.SetRelease(target); err != nil {
		t.Fatal(err)
	}
	identity := rolloutIdentityInBucketRange(t, 0, 99)
	policy, err := memory.StartReleaseRollout(t.Context(), store.StartReleaseRolloutRequest{
		Platform: defaultReleasePlatform, TargetVersion: target.Version,
		CanarySEIdentities: []string{identity},
	})
	if err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	server := NewServer(reg, memory, ServerConfig{}, logger)
	defer server.Close()
	serving := protocol.UpdateLifecycleServing
	provider := reg.Register("fresh-target", nil, &protocol.RegisterMessage{
		Version: target.Version, UpdateLifecycleState: &serving,
	})
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: identity, SerialNumber: "serial",
	})
	provider.Mu().Lock()
	provider.Version = target.Version
	provider.TrustLevel = registry.TrustHardware
	provider.Attested = true
	provider.DeviceEvidence = registry.DeviceEvidence{
		SEPublicKey: identity, Serial: "serial", VerifiedAt: time.Now(),
		ExpiresAt: time.Now().Add(time.Hour), EvidenceGeneration: 1,
	}
	provider.Mu().Unlock()
	commands := 0
	reg.SetReleaseUpdateSenderForTesting(func(context.Context, string, protocol.ReleaseUpdateMessage) error {
		commands++
		return nil
	})
	server.reconcileConnectedProviderReleaseRollout(provider.ID)
	if err := server.dispatchApprovedReleaseUpdates(policy); err != nil {
		t.Fatal(err)
	}
	provider.Mu().Lock()
	approved := provider.RolloutReleaseApproved
	targetBinding := provider.UpdateTargetVersion
	generation := provider.UpdateDesiredGeneration
	provider.Mu().Unlock()
	if !approved || targetBinding != "" || generation != 0 || commands != 0 {
		t.Fatalf("fresh target state approved=%v target=%q generation=%d commands=%d",
			approved, targetBinding, generation, commands)
	}
}

func TestReadyReconnectRetriesAfterFreshApplicationEvidence(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	target := &store.Release{Version: "5.0.0", Platform: defaultReleasePlatform}
	if err := memory.SetRelease(target); err != nil {
		t.Fatal(err)
	}
	identity := rolloutIdentityInBucketRange(t, 0, 99)
	if _, err := memory.StartReleaseRollout(t.Context(), store.StartReleaseRolloutRequest{
		Platform: defaultReleasePlatform, TargetVersion: target.Version,
		CanarySEIdentities: []string{identity},
	}); err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	server := NewServer(reg, memory, ServerConfig{}, logger)
	defer server.Close()
	ready := protocol.UpdateLifecycleReady
	provider := reg.Register("ready-reconnect", nil, &protocol.RegisterMessage{
		Version: target.Version, UpdateLifecycleState: &ready,
	})
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: identity, SerialNumber: "serial",
	})
	provider.Mu().Lock()
	provider.Version = target.Version
	provider.TrustLevel = registry.TrustHardware
	provider.Attested = true
	provider.DeviceEvidence = registry.DeviceEvidence{
		SEPublicKey: identity, Serial: "serial", VerifiedAt: time.Now(),
		ExpiresAt: time.Now().Add(time.Hour), EvidenceGeneration: 1,
	}
	provider.Mu().Unlock()
	server.reconcileConnectedProviderReleaseRollout(provider.ID)
	provider.Mu().Lock()
	before := provider.RolloutReleaseApproved
	provider.ApplicationEvidence = registry.ApplicationEvidence{
		Version: target.Version, EvidenceGeneration: 1,
	}
	provider.Mu().Unlock()
	if before {
		t.Fatal("ready reconnect approved before fresh application evidence")
	}
	server.handleRuntimeCapabilitiesPromoted(provider.ID)
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	if !provider.RolloutReleaseApproved || !provider.ReleaseUpdateReadyLocked() {
		t.Fatalf("fresh evidence did not reconcile ready provider: approved=%v target=%q generation=%d",
			provider.RolloutReleaseApproved, provider.UpdateTargetVersion,
			provider.UpdateDesiredGeneration)
	}
}

func TestInvalidAttestationNeverReceivesRolloutCommand(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	previous := &store.Release{Version: "5.9.0", Platform: defaultReleasePlatform}
	target := &store.Release{Version: "6.0.0", Platform: defaultReleasePlatform}
	if err := memory.SetRelease(previous); err != nil {
		t.Fatal(err)
	}
	if err := memory.SetRelease(target); err != nil {
		t.Fatal(err)
	}
	identity := rolloutIdentityInBucketRange(t, 0, 99)
	policy, err := memory.StartReleaseRollout(t.Context(), store.StartReleaseRolloutRequest{
		Platform: defaultReleasePlatform, TargetVersion: target.Version,
		CanarySEIdentities: []string{identity},
	})
	if err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	server := NewServer(reg, memory, ServerConfig{}, logger)
	defer server.Close()
	serving := protocol.UpdateLifecycleServing
	provider := reg.Register("invalid-attestation", nil, &protocol.RegisterMessage{
		Version: previous.Version, UpdateLifecycleState: &serving,
	})
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: false, PublicKey: identity, SerialNumber: "serial",
	})
	provider.Mu().Lock()
	provider.Version = previous.Version
	provider.TrustLevel = registry.TrustHardware
	provider.DeviceEvidence = registry.DeviceEvidence{
		SEPublicKey: identity, Serial: "serial", VerifiedAt: time.Now(),
		ExpiresAt: time.Now().Add(time.Hour), EvidenceGeneration: 1,
	}
	provider.Mu().Unlock()
	commands := 0
	reg.SetReleaseUpdateSenderForTesting(func(context.Context, string, protocol.ReleaseUpdateMessage) error {
		commands++
		return nil
	})
	server.reconcileConnectedProviderReleaseRollout(provider.ID)
	if err := server.dispatchApprovedReleaseUpdates(policy); err != nil {
		t.Fatal(err)
	}
	provider.Mu().Lock()
	approved := provider.RolloutReleaseApproved
	provider.Mu().Unlock()
	if approved || commands != 0 {
		t.Fatalf("invalid attestation approved=%v commands=%d", approved, commands)
	}
}

func TestStalePostCASDispatchCannotOverwriteNewerRevision(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	if err := memory.SetRelease(&store.Release{
		Version: "7.0.0", Platform: defaultReleasePlatform,
	}); err != nil {
		t.Fatal(err)
	}
	old, err := memory.StartReleaseRollout(t.Context(), store.StartReleaseRolloutRequest{
		Platform: defaultReleasePlatform, TargetVersion: "7.0.0",
		CanarySEIdentities: []string{rolloutIdentityInBucketRange(t, 0, 99)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := memory.TransitionReleaseRollout(t.Context(), store.ReleaseRolloutTransitionRequest{
		Platform: defaultReleasePlatform, ExpectedRevision: old.Revision,
		Action: "promote", Stage: store.RolloutStage1,
	}); err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	server := NewServer(registry.New(logger), memory, ServerConfig{}, logger)
	defer server.Close()
	if err := server.dispatchApprovedReleaseUpdates(old); !errors.Is(err, store.ErrRolloutConflict) {
		t.Fatalf("stale dispatch error=%v", err)
	}
}

func TestPauseCancelsAndDrainsInFlightReleaseDispatch(t *testing.T) {
	memory := store.NewMemory(store.Config{})
	previous := &store.Release{Version: "8.0.0", Platform: defaultReleasePlatform}
	target := &store.Release{Version: "9.0.0", Platform: defaultReleasePlatform}
	if err := memory.SetRelease(previous); err != nil {
		t.Fatal(err)
	}
	if err := memory.SetRelease(target); err != nil {
		t.Fatal(err)
	}
	identity := rolloutIdentityInBucketRange(t, 0, 99)
	policy, err := memory.StartReleaseRollout(t.Context(), store.StartReleaseRolloutRequest{
		Platform: defaultReleasePlatform, TargetVersion: target.Version,
		CanarySEIdentities: []string{identity},
	})
	if err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	reg := registry.New(logger)
	server := NewServer(reg, memory, ServerConfig{}, logger)
	defer server.Close()
	serving := protocol.UpdateLifecycleServing
	provider := reg.Register("cancel-boundary", nil, &protocol.RegisterMessage{
		Version: previous.Version, UpdateLifecycleState: &serving,
	})
	provider.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: identity, SerialNumber: "serial",
	})
	provider.Mu().Lock()
	provider.Version = previous.Version
	provider.TrustLevel = registry.TrustHardware
	provider.Attested = true
	provider.DeviceEvidence = registry.DeviceEvidence{
		SEPublicKey: identity, Serial: "serial", VerifiedAt: time.Now(),
		ExpiresAt: time.Now().Add(time.Hour), EvidenceGeneration: 1,
	}
	provider.Mu().Unlock()
	started := make(chan struct{})
	reg.SetReleaseUpdateSenderForTesting(func(ctx context.Context, _ string, _ protocol.ReleaseUpdateMessage) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	dispatchDone := make(chan error, 1)
	go func() { dispatchDone <- server.dispatchApprovedReleaseUpdates(policy) }()
	<-started
	paused, err := server.transitionReleaseRolloutSerialized(t.Context(), store.ReleaseRolloutTransitionRequest{
		Platform: defaultReleasePlatform, ExpectedRevision: policy.Revision,
		Action: "pause", Reason: "operator", Actor: "admin",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !paused.Paused {
		t.Fatal("pause did not commit after draining dispatch")
	}
	if err := <-dispatchDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("dispatch error=%v, want cancellation", err)
	}
}

func TestReconnectDedupeCapFailsClosedWithoutLiveEviction(t *testing.T) {
	monitor := newRolloutHealthMonitor()
	now := time.Now()
	monitor.policyGeneration = 1
	monitor.reconnectLastPruneEpoch = rolloutEpoch(now)
	for i := range rolloutReconnectMaxKeys {
		monitor.reconnectSettled[rolloutReconnectKey{
			identity: fmt.Sprintf("identity-%d", i), generation: 1,
		}] = now
	}
	monitor.recordReconnect("overflow-identity", 1, false, now)
	if !monitor.reconnectOverflow || len(monitor.reconnectSettled) != rolloutReconnectMaxKeys {
		t.Fatalf("overflow=%v size=%d", monitor.reconnectOverflow, len(monitor.reconnectSettled))
	}
	evaluation := EvaluateRolloutHealth(nil, RolloutHealthObservations{
		ReconnectOverflow: true,
	}, defaultRolloutHealthThresholds())
	if evaluation.Healthy || evaluation.PauseReason != RolloutPauseReconnectCrashRate {
		t.Fatalf("overflow evaluation=%+v", evaluation)
	}
}

func TestFleetMetricSameBucketReplacesAggregateObservation(t *testing.T) {
	now := time.Now()
	var window rolloutMetricWindow
	window.observeAggregate(now, 0.1)
	window.observeAggregate(now, 0.9)
	observation := window.snapshot(now)
	if observation.Observations != 1 || observation.Ratio != 0.9 {
		t.Fatalf("same-bucket aggregate=%+v", observation)
	}
	window.observe(now, 0)
	observation = window.snapshot(now)
	if observation.Observations != 2 {
		t.Fatalf("event-weighted reconnect sample count=%d", observation.Observations)
	}
}
