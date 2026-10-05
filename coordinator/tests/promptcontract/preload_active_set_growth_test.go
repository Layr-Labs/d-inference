package promptcontract_test

import (
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
)

// D64 scopes failure backoff to the exact requested set. An unchanged partial
// A/B batch must wait, but newly verified C must not inherit that batch's wait.
// This is an independent expected-behavior oracle for the prepared policy,
// not permission to drop B, change capacity, refresh generations or waive D64.
func TestPreloadActiveSetVerifiedGrowthBypassesPriorSetBackoff(t *testing.T) {
	policy := preload.NewPreloadActiveSet()
	original := activeSetInput(2, 3)
	originalKey := activeSetReconcile(t, policy, 0, original)
	wantAB := []string{activeSetContract(1), activeSetContract(2)}
	if !slices.Equal(originalKey.Desired, wantAB) {
		t.Fatal("setup did not select full within-capacity A/B set")
	}
	first, ok := policy.BeginAttempt(0)
	if !ok {
		t.Fatal("initial A/B preload was not admitted")
	}
	if !policy.CompleteAttempt(0, first, []string{activeSetContract(1)}, 60*time.Second) {
		t.Fatal("setup did not accept validated A-success/B-failure result")
	}
	if !slices.Equal(policy.Successes(), []string{activeSetContract(1)}) {
		t.Fatal("partial publication must contain A only")
	}
	// Retain the independent negative: polling the same exact V/D is not a
	// reason to erase failed-batch backoff or admit an overlapping operation.
	unchanged := activeSetReconcile(t, policy, 500*time.Millisecond, original)
	if !unchanged.Equal(originalKey) {
		t.Fatal("unchanged poll unexpectedly changed the exact identity")
	}
	if _, admitted := policy.BeginAttempt(500 * time.Millisecond); admitted {
		t.Fatal("unchanged A/B batch bypassed its 60-second backoff")
	}

	grown := activeSetInput(3, 3)
	if grown.CatalogGeneration != original.CatalogGeneration || grown.ChildGeneration != original.ChildGeneration {
		t.Fatal("fixture must grow verification without changing catalog or child generation")
	}
	current := activeSetReconcile(t, policy, time.Second, grown)
	wantABC := []string{activeSetContract(1), activeSetContract(2), activeSetContract(3)}
	if !slices.Equal(current.Desired, wantABC) || len(current.Verified) != 3 || len(current.Admissible) != 3 || current.Capacity != 3 {
		t.Fatal("new exact V/D must include A, B and C within the unchanged capacity")
	}
	if current.Equal(originalKey) || len(policy.Successes()) != 0 {
		t.Fatal("new exact identity must fence the prior partial publication")
	}
	next, admitted := policy.BeginAttempt(time.Second)
	if !admitted {
		t.Fatal("new exact A/B/C set inherited old A/B failure backoff; C must be eligible for preload at t=1s")
	}
	if !next.Key.Equal(current) || next.Operation == first.Operation {
		t.Fatal("new preload must own a fresh lease for the complete current A/B/C key")
	}
}
