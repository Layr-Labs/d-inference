package store

import (
	"context"
	"crypto/elliptic"
	"encoding/base64"
	"errors"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

func seedRolloutRelease(t *testing.T, store *MemoryStore, version string) {
	t.Helper()
	if err := store.SetRelease(&Release{Version: version, Platform: "macos-arm64", Backend: "mlx-swift", Active: true}); err != nil {
		t.Fatal(err)
	}
}

func rolloutTestSEIdentity(seed byte) string {
	scalar := make([]byte, 32)
	scalar[31] = seed
	x, y := elliptic.P256().ScalarBaseMult(scalar)
	return base64.StdEncoding.EncodeToString(elliptic.Marshal(elliptic.P256(), x, y))
}

func TestReleaseRolloutCASPauseResumeAndAudit(t *testing.T) {
	memory := NewMemory(Config{})
	seedRolloutRelease(t, memory, "1.0.0")
	seedRolloutRelease(t, memory, "1.1.0")
	policy, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: "1.1.0",
		CanarySEIdentities: []string{
			rolloutTestSEIdentity(1), rolloutTestSEIdentity(2), rolloutTestSEIdentity(2),
		}, Actor: "admin",
	})
	if err != nil {
		t.Fatal(err)
	}
	if policy.Stage != RolloutStageCanary || policy.PreviousVersion != "1.0.0" || len(policy.CanarySEIdentities) != 2 {
		t.Fatalf("unexpected initial policy: %+v", policy)
	}

	var successes int
	var lock sync.Mutex
	var wait sync.WaitGroup
	for range 2 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
				Platform: "macos-arm64", ExpectedRevision: policy.Revision,
				Action: "promote", Stage: RolloutStage1, Actor: "admin",
			})
			if err == nil {
				lock.Lock()
				successes++
				lock.Unlock()
			} else if !errors.Is(err, ErrRolloutConflict) {
				t.Errorf("unexpected concurrent error: %v", err)
			}
		}()
	}
	wait.Wait()
	if successes != 1 {
		t.Fatalf("CAS successes = %d, want 1", successes)
	}

	policy, err = memory.GetReleaseRollout(context.Background(), "macos-arm64")
	if err != nil {
		t.Fatal(err)
	}
	policy, err = memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
		Platform: policy.Platform, ExpectedRevision: policy.Revision,
		Action: "automatic_pause", Reason: "server_5xx_rate", Actor: "system",
	})
	if err != nil || !policy.Paused || policy.PauseReason != "server_5xx_rate" {
		t.Fatalf("pause = %+v, err=%v", policy, err)
	}
	if _, err := memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
		Platform: policy.Platform, ExpectedRevision: policy.Revision,
		Action: "promote", Stage: RolloutStage5,
	}); !errors.Is(err, ErrRolloutInvalid) {
		t.Fatalf("paused promotion error = %v", err)
	}
	policy, err = memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
		Platform: policy.Platform, ExpectedRevision: policy.Revision, Action: "resume", Actor: "admin",
	})
	if err != nil || policy.Paused || policy.PauseReason != "" {
		t.Fatalf("resume = %+v, err=%v", policy, err)
	}
	if policy.DesiredGeneration != 1 {
		t.Fatalf("policy-only transitions changed target generation: %d", policy.DesiredGeneration)
	}
	transitions, err := memory.ListReleaseRolloutTransitions(context.Background(), policy.Platform)
	if err != nil || len(transitions) != 4 {
		t.Fatalf("audit rows = %+v, err=%v", transitions, err)
	}
	for i := 1; i < len(transitions); i++ {
		if transitions[i].ID <= transitions[i-1].ID || transitions[i].ResultRevision <= transitions[i-1].ResultRevision {
			t.Fatalf("audit is not immutable ordered history: %+v", transitions)
		}
	}
}

func TestReleaseRolloutRejectsSkippedStagesAndDowngrade(t *testing.T) {
	memory := NewMemory(Config{})
	seedRolloutRelease(t, memory, "2.0.0")
	seedRolloutRelease(t, memory, "2.1.0")
	policy, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: "2.1.0",
		CanarySEIdentities: []string{rolloutTestSEIdentity(3)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
		Platform: policy.Platform, ExpectedRevision: policy.Revision,
		Action: "promote", Stage: RolloutStage25,
	}); !errors.Is(err, ErrRolloutInvalid) {
		t.Fatalf("skipped-stage error = %v", err)
	}
	for _, stage := range []RolloutStage{RolloutStage1, RolloutStage5, RolloutStage25, RolloutStage50, RolloutStage100} {
		policy, err = memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
			Platform: policy.Platform, ExpectedRevision: policy.Revision, Action: "promote", Stage: stage,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if _, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: policy.Platform, TargetVersion: "2.0.0", ExpectedRevision: policy.Revision,
	}); !errors.Is(err, ErrRolloutInvalid) {
		t.Fatalf("downgrade error = %v", err)
	}
}

func completeRolloutForTest(t *testing.T, memory *MemoryStore, policy *ReleaseRolloutPolicy) *ReleaseRolloutPolicy {
	t.Helper()
	var err error
	for _, stage := range []RolloutStage{
		RolloutStage1, RolloutStage5, RolloutStage25, RolloutStage50, RolloutStage100,
	} {
		policy, err = memory.TransitionReleaseRollout(context.Background(), ReleaseRolloutTransitionRequest{
			Platform: policy.Platform, ExpectedRevision: policy.Revision,
			Action: "promote", Stage: stage,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	return policy
}

func TestNextRolloutPreviousIsCompletedTargetNotUnrolledInventory(t *testing.T) {
	memory := NewMemory(Config{})
	seedRolloutRelease(t, memory, "1.0.0")
	first, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: "1.0.0",
		CanarySEIdentities: []string{rolloutTestSEIdentity(4)},
	})
	if err != nil {
		t.Fatal(err)
	}
	first = completeRolloutForTest(t, memory, first)
	seedRolloutRelease(t, memory, "1.5.0")
	seedRolloutRelease(t, memory, "2.0.0")
	next, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: "2.0.0", ExpectedRevision: first.Revision,
		CanarySEIdentities: []string{rolloutTestSEIdentity(5)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if next.PreviousVersion != "1.0.0" {
		t.Fatalf("previous = %q, want completed target 1.0.0", next.PreviousVersion)
	}
}

func TestRolloutSemVerRCToFinalAndImmutableArtifacts(t *testing.T) {
	memory := NewMemory(Config{})
	rc := &Release{Version: "2.0.1-rc.1", Platform: "macos-arm64", BinaryHash: "a", URL: "https://example/rc"}
	final := &Release{Version: "2.0.1", Platform: "macos-arm64", BinaryHash: "b", URL: "https://example/final"}
	if err := memory.SetRelease(rc); err != nil {
		t.Fatal(err)
	}
	policy, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: rc.Version,
		CanarySEIdentities: []string{rolloutTestSEIdentity(6)},
	})
	if err != nil {
		t.Fatal(err)
	}
	policy = completeRolloutForTest(t, memory, policy)
	if err := memory.SetRelease(final); err != nil {
		t.Fatal(err)
	}
	if _, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: final.Version, ExpectedRevision: policy.Revision,
		CanarySEIdentities: []string{rolloutTestSEIdentity(7)},
	}); err != nil {
		t.Fatalf("RC to final rollout rejected: %v", err)
	}
	changed := *final
	changed.BinaryHash = "different"
	if err := memory.SetRelease(&changed); !errors.Is(err, ErrReleaseArtifactImmutable) {
		t.Fatalf("mutable release artifact error = %v", err)
	}
}

func TestPostgresInitialRolloutUniqueRaceMapsToConflict(t *testing.T) {
	err := mapRolloutCASErr(&pgconn.PgError{Code: "23505"})
	if !errors.Is(err, ErrRolloutConflict) {
		t.Fatalf("unique race mapped to %v", err)
	}
}

func TestReleaseRolloutRequiresCanonicalNonemptyCanary(t *testing.T) {
	memory := NewMemory(Config{})
	seedRolloutRelease(t, memory, "8.0.0")
	if _, err := memory.StartReleaseRollout(context.Background(), StartReleaseRolloutRequest{
		Platform: "macos-arm64", TargetVersion: "8.0.0",
	}); !errors.Is(err, ErrRolloutInvalid) {
		t.Fatalf("empty canary error=%v", err)
	}
}
