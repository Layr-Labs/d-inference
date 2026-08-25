package sandboxcontrol

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestCommandDispatchTimeoutUsesRemainingAbsoluteDeadline(t *testing.T) {
	createdAt := time.Date(2026, 8, 25, 11, 0, 0, 0, time.UTC)
	command := &store.SandboxCommand{
		TimeoutSeconds: 900,
		CreatedAt:      createdAt,
	}
	if timeout, ok := commandDispatchTimeoutSeconds(
		command,
		createdAt.Add(10*time.Second+500*time.Millisecond),
	); !ok || timeout != 889 {
		t.Fatalf("remaining dispatch timeout = (%d, %v), want (889, true)", timeout, ok)
	}
	if timeout, ok := commandDispatchTimeoutSeconds(
		command,
		command.Deadline(),
	); ok || timeout != 0 {
		t.Fatalf("expired dispatch timeout = (%d, %v), want (0, false)", timeout, ok)
	}
}

func TestLegacyRenewalObservationAcceptsOnlyAdvancingFence(t *testing.T) {
	legacy := &store.SandboxOperation{
		Kind:         store.SandboxOperationKindRenew,
		FencingToken: 10,
	}
	if renewalObservationFenceMatches(legacy, 10) {
		t.Fatal("legacy renewal accepted a non-advancing fence")
	}
	if !renewalObservationFenceMatches(legacy, 12) {
		t.Fatal("legacy renewal rejected an advancing observed fence")
	}

	current := &store.SandboxOperation{
		Kind:                  store.SandboxOperationKindRenew,
		FencingToken:          10,
		RequestedFencingToken: 12,
	}
	if !renewalObservationFenceMatches(current, 12) ||
		renewalObservationFenceMatches(current, 11) {
		t.Fatal("current renewal did not require its exact reserved fence")
	}
}
