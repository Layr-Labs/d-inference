package api

import (
	"log/slog"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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

func TestInferenceErrorReasonPrecedenceAndDerivation(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-reason"}

	providerReason := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		Error:       "token_budget_exhausted: request queue full",
		StatusCode:  http.StatusInternalServerError,
		ErrorReason: "jinja_channel_tags",
	})
	if providerReason.ErrorReason != "jinja_channel_tags" {
		t.Fatalf("provider-supplied reason should win, got %+v", providerReason)
	}

	derivedTokenBudget := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		Error:      "token_budget_exhausted: request queue full",
		StatusCode: http.StatusInternalServerError,
	})
	if derivedTokenBudget.ErrorReason != "token_budget_exhausted" {
		t.Fatalf("token-budget reason = %q, want token_budget_exhausted", derivedTokenBudget.ErrorReason)
	}

	queueTimeout := pendingRouteOutcome(pr, "timeout", "queue_timeout", http.StatusTooManyRequests)
	if queueTimeout.ErrorReason != "capacity_timeout" {
		t.Fatalf("queue timeout reason = %q, want capacity_timeout", queueTimeout.ErrorReason)
	}

	clientGone := pendingRouteOutcome(pr, "cancelled", "client_gone", 0)
	if clientGone.ErrorReason != "cancelled" {
		t.Fatalf("client gone reason = %q, want cancelled", clientGone.ErrorReason)
	}

	unknown := routeOutcome("error", "unclassified", http.StatusTeapot)
	if unknown.ErrorReason != "unknown" {
		t.Fatalf("unknown fallback reason = %q, want unknown", unknown.ErrorReason)
	}

	invalidProviderReason := preCommitProviderErrorOutcome(pr, protocol.InferenceErrorMessage{
		Error:       "raw provider stack trace should not persist",
		StatusCode:  http.StatusInternalServerError,
		ErrorReason: "raw provider stack trace should not persist",
	})
	if invalidProviderReason.ErrorReason != "unknown" {
		t.Fatalf("invalid provider reason = %q, want unknown", invalidProviderReason.ErrorReason)
	}
}

func TestInferenceErrorMetricEmitsReasonAndModel(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	srv.updateInferenceRouteOutcomeWithModel("req-metric", 1, "gpt-oss-20b", &store.InferenceRouteOutcome{
		FinalStatus: "error",
		ErrorClass:  "provider_error",
		ErrorCode:   http.StatusInternalServerError,
		ErrorReason: "jinja_null_bridge",
	})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	metrics := findMetrics(packets, metricInferenceError)
	if len(metrics) == 0 {
		t.Fatalf("missing %s metric; packets=%v", metricInferenceError, packets)
	}
	if !hasMetric(metrics, "reason:jinja_null_bridge") {
		t.Fatalf("missing reason tag; packets=%v", metrics)
	}
	if !hasMetric(metrics, "model:gpt-oss-20b") {
		t.Fatalf("missing model tag; packets=%v", metrics)
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
