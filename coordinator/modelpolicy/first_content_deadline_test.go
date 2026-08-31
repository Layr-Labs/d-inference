package modelpolicy

import (
	"testing"
	"time"
)

func TestFirstContentDeadlinesByExactModel(t *testing.T) {
	tests := []struct {
		name            string
		model           string
		promptTokens    int
		wantUpstream    time.Duration
		wantCoordinator time.Duration
	}{
		{
			name:            "ordinary model",
			model:           "ordinary-model",
			promptTokens:    321,
			wantUpstream:    10*time.Second + 321*time.Millisecond,
			wantCoordinator: 9*time.Second + 321*time.Millisecond,
		},
		{
			name:            "exact Qwen3-VL instruct",
			model:           Qwen3VL30BA3BInstructModelID,
			promptTokens:    321,
			wantUpstream:    5*time.Second + 321*time.Millisecond,
			wantCoordinator: 4*time.Second + 321*time.Millisecond,
		},
		{
			name:            "Qwen3-VL lookalike",
			model:           Qwen3VL30BA3BInstructModelID + "-preview",
			promptTokens:    321,
			wantUpstream:    10*time.Second + 321*time.Millisecond,
			wantCoordinator: 9*time.Second + 321*time.Millisecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := UpstreamFirstContentDeadline(
				tt.model, tt.promptTokens, StandardUpstreamFirstContentBase,
			); got != tt.wantUpstream {
				t.Fatalf("upstream deadline = %v, want %v", got, tt.wantUpstream)
			}
			if got := CoordinatorFirstContentDeadline(
				tt.model, tt.promptTokens,
				StandardUpstreamFirstContentBase-FirstContentResponseHeadroom,
			); got != tt.wantCoordinator {
				t.Fatalf("coordinator deadline = %v, want %v", got, tt.wantCoordinator)
			}
		})
	}
}

func TestFirstContentDeadlineClampsNegativePromptTokens(t *testing.T) {
	if got := UpstreamFirstContentDeadline(
		Qwen3VL30BA3BInstructModelID, -1, StandardUpstreamFirstContentBase,
	); got != Qwen3VL30BA3BInstructUpstreamFirstContentBase {
		t.Fatalf("upstream deadline = %v, want base only", got)
	}
	if got := CoordinatorFirstContentDeadline(
		Qwen3VL30BA3BInstructModelID, -1, 9*time.Second,
	); got != Qwen3VL30BA3BInstructCoordinatorFirstContentBase {
		t.Fatalf("coordinator deadline = %v, want base only", got)
	}
}

func TestOrdinaryDeadlineBasesRemainConfigurable(t *testing.T) {
	const promptTokens = 25
	if got, want := UpstreamFirstContentDeadline(
		"ordinary-model", promptTokens, 12*time.Second,
	), 12*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("upstream deadline = %v, want %v", got, want)
	}
	if got, want := CoordinatorFirstContentDeadline(
		"ordinary-model", promptTokens, 8*time.Second,
	), 8*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("coordinator deadline = %v, want %v", got, want)
	}
}

func TestModelOverridesNeverLoosenTighterGlobalDeadline(t *testing.T) {
	const promptTokens = 25
	if got, want := UpstreamFirstContentDeadline(
		Qwen3VL30BA3BInstructModelID, promptTokens, 3*time.Second,
	), 3*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("upstream deadline = %v, want tighter global %v", got, want)
	}
	if got, want := CoordinatorFirstContentDeadline(
		Qwen3VL30BA3BInstructModelID, promptTokens, 3*time.Second,
	), 3*time.Second+25*time.Millisecond; got != want {
		t.Fatalf("coordinator deadline = %v, want tighter global %v", got, want)
	}
}
