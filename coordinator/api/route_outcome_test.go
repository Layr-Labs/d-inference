package api

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCommittedRouteOutcomeIsNonTerminal(t *testing.T) {
	now := time.Now()
	pr := &registry.PendingRequest{
		RequestID: "req-commit",
		Timing: &registry.RequestTiming{
			ReceivedAt:   now.Add(-100 * time.Millisecond),
			DispatchedAt: now.Add(-50 * time.Millisecond),
		},
	}
	pr.MarkFirstChunkArrived()
	out := committedRouteOutcome(pr)
	if out.FinalStatus != "" {
		t.Fatalf("FinalStatus = %q, want empty until provider terminal", out.FinalStatus)
	}
	if out.ActualTTFTMs == 0 || out.DispatchToFirstChunkMs == 0 {
		t.Fatalf("commit outcome should still carry TTFT fields: %+v", out)
	}
}

func TestPostCommitProviderDisconnectOutcome(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-disconnect"}
	out := postCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		Error:      "provider disconnected",
		StatusCode: 502,
	})
	if out.FinalStatus != "partial_success" {
		t.Fatalf("FinalStatus = %q, want partial_success", out.FinalStatus)
	}
	if out.ErrorClass != "provider_disconnect_after_commit" {
		t.Fatalf("ErrorClass = %q, want provider_disconnect_after_commit", out.ErrorClass)
	}
	if !out.AdmittedButFailed {
		t.Fatal("provider disconnect after commit should still mark admitted_but_failed")
	}
}

func TestPreCommitProviderDisconnectOutcome(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-disconnect-pre"}
	out := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		Error:      "provider disconnected",
		StatusCode: 502,
	})
	if out.FinalStatus != "error" {
		t.Fatalf("FinalStatus = %q, want error", out.FinalStatus)
	}
	if out.ErrorClass != "provider_disconnect_pre_commit" {
		t.Fatalf("ErrorClass = %q, want provider_disconnect_pre_commit", out.ErrorClass)
	}
}

func TestPostCommitTimeoutAndNoTerminalArePartialSuccess(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-partial"}
	if out := postCommitStreamTimeoutOutcome(pr); out.FinalStatus != "partial_success" || out.ErrorClass != "stream_timeout_after_commit" {
		t.Fatalf("stream timeout outcome = %+v", out)
	}
	if out := noTerminalAfterCancelOutcome(pr); out.FinalStatus != "partial_success" || out.ErrorClass != "no_terminal_after_cancel" {
		t.Fatalf("no-terminal outcome = %+v", out)
	}
}

func TestSpeculativeLoserOutcome(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-loser", UsedBackup: true}
	out := speculativeLoserOutcome(pr)
	if out.FinalStatus != "cancelled" {
		t.Fatalf("FinalStatus = %q, want cancelled", out.FinalStatus)
	}
	if out.ErrorClass != "speculative_loser" {
		t.Fatalf("ErrorClass = %q, want speculative_loser", out.ErrorClass)
	}
	if !out.UsedBackup {
		t.Fatal("speculative loser outcome should preserve used_backup")
	}
	if out.BackupWon {
		t.Fatal("speculative loser outcome must not set backup_won")
	}
}
