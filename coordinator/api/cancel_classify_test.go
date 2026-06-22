package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCancelClassification(t *testing.T) {
	cases := []struct {
		name        string
		status      string
		class       string
		code        int
		wantPhase   string
		wantSource  string
		wantSettled string
	}{
		{
			name: "pre-commit client gone", status: "cancelled", class: "client_gone",
			wantPhase: cancelPhaseBeforeFirstToken, wantSource: cancelSourceClientClosed, wantSettled: partialSettlementZeroDelivered,
		},
		{
			name: "pre-response client gone (non-streaming)", status: "cancelled", class: "client_gone_before_response",
			wantPhase: cancelPhaseBeforeFirstToken, wantSource: cancelSourceClientClosed, wantSettled: partialSettlementZeroDelivered,
		},
		{
			name: "speculative loser", status: "cancelled", class: "speculative_loser",
			wantPhase: cancelPhaseSpeculativeLoser, wantSource: cancelSourceSpeculativeLoser, wantSettled: partialSettlementNone,
		},
		{
			name: "after-commit provider completed", status: "partial_success", class: errorClassClientGoneAfterCommitCompleted,
			wantPhase: cancelPhaseAfterProviderComplete, wantSource: cancelSourceClientClosed, wantSettled: partialSettlementSettled,
		},
		{
			name: "no terminal after cancel", status: "partial_success", class: "no_terminal_after_cancel",
			wantPhase: cancelPhaseAfterFirstToken, wantSource: cancelSourceClientClosed, wantSettled: partialSettlementExpired,
		},
		{
			name: "after-commit provider error", status: "partial_success", class: "client_gone_after_commit_provider_error",
			wantPhase: cancelPhaseAfterFirstToken, wantSource: cancelSourceProviderError, wantSettled: partialSettlementRefunded,
		},
		{
			name: "after-commit provider disconnected", status: "partial_success", class: "client_gone_after_commit_provider_disconnected",
			wantPhase: cancelPhaseAfterFirstToken, wantSource: cancelSourceProviderDisconnect, wantSettled: partialSettlementRefunded,
		},
		{
			name: "after-commit provider cancel-ack (499)", status: "partial_success", class: "client_gone_after_commit_provider_cancelled", code: 499,
			wantPhase: cancelPhaseAfterFirstToken, wantSource: cancelSourceClientClosed, wantSettled: partialSettlementRefunded,
		},
		// Non-cancellation outcomes must leave every dimension empty so the
		// merge-on-nonzero bridge never overwrites a real value.
		{name: "clean success", status: "success", class: ""},
		{name: "provider error (consumer present)", status: "error", class: "provider_error", code: 500},
		{name: "provider stream timeout (stall, not a client cancel)", status: "partial_success", class: "stream_timeout_after_commit", code: 504},
		{name: "pre-commit provider disconnect", status: "error", class: "provider_disconnect_pre_commit", code: 502},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := deriveCancelPhase(tc.status, tc.class); got != tc.wantPhase {
				t.Errorf("deriveCancelPhase(%q,%q) = %q, want %q", tc.status, tc.class, got, tc.wantPhase)
			}
			if got := deriveCancelSource(tc.status, tc.class, tc.code); got != tc.wantSource {
				t.Errorf("deriveCancelSource(%q,%q,%d) = %q, want %q", tc.status, tc.class, tc.code, got, tc.wantSource)
			}
			if got := deriveCancelSettlement(tc.status, tc.class); got != tc.wantSettled {
				t.Errorf("deriveCancelSettlement(%q,%q) = %q, want %q", tc.status, tc.class, got, tc.wantSettled)
			}
		})
	}
}

// TestRouteOutcomeWithReasonPopulatesCancelDimensions verifies the central hook
// in routeOutcomeWithReason wires the derivation onto the outcome struct.
func TestRouteOutcomeWithReasonPopulatesCancelDimensions(t *testing.T) {
	out := routeOutcomeWithReason("cancelled", "client_gone", 0, "", "")
	if out.CancelPhase != cancelPhaseBeforeFirstToken || out.CancelSource != cancelSourceClientClosed || out.PartialSettlementStatus != partialSettlementZeroDelivered {
		t.Fatalf("cancel dimensions not populated: %+v", out)
	}
	// A provider error is not a cancellation: dimensions stay empty.
	out = routeOutcomeWithReason("error", "provider_error", 500, "", "boom")
	if out.CancelPhase != "" || out.CancelSource != "" || out.PartialSettlementStatus != "" {
		t.Fatalf("non-cancel outcome should leave cancel dimensions empty: %+v", out)
	}
}

// TestCancelSignalTimestampStampedOnlyAtSend verifies cancel_signal_sent_at is
// populated ONLY when an actual provider cancel was sent (MarkCancelSignalSent),
// not merely because the outcome is a cancellation — so a queued cancel with no
// provider, or a build before any send, leaves it unset.
func TestCancelSignalTimestampStampedOnlyAtSend(t *testing.T) {
	// No provider cancel sent yet: a cancellation outcome must NOT stamp it.
	pr := &registry.PendingRequest{RequestID: "req-spec", Attempt: 1}
	out := pendingRouteOutcome(pr, "cancelled", "speculative_loser", 0)
	if out.CancelPhase != cancelPhaseSpeculativeLoser {
		t.Fatalf("expected speculative_loser phase, got %q", out.CancelPhase)
	}
	if out.CancelSignalSentAtMs != 0 {
		t.Fatalf("cancel_signal_sent_at_ms must be unset when no provider cancel was sent, got %d", out.CancelSignalSentAtMs)
	}

	// After the real send path stamps it (cancelDispatch / post-commit defer), the
	// outcome carries it.
	pr.MarkCancelSignalSent()
	out = pendingRouteOutcome(pr, "cancelled", "client_gone", 0)
	if out.CancelSignalSentAtMs == 0 {
		t.Fatal("cancel_signal_sent_at_ms should be set after an actual send (MarkCancelSignalSent)")
	}

	// A non-cancellation outcome (no send) must not stamp the cancel-signal time.
	pr2 := &registry.PendingRequest{RequestID: "req-ok", Attempt: 1}
	out2 := pendingRouteOutcome(pr2, "success", "", 0)
	if out2.CancelSignalSentAtMs != 0 {
		t.Fatalf("non-cancel outcome should not stamp cancel_signal_sent_at_ms, got %d", out2.CancelSignalSentAtMs)
	}
}

func TestRefineCancelSourceForIdle(t *testing.T) {
	cases := []struct {
		name   string
		source string
		phase  string
		gapMs  float64
		want   string
	}{
		{"idle gap over threshold upgrades client_closed", cancelSourceClientClosed, cancelPhaseAfterFirstToken, streamIdleGapThresholdMs + 1, cancelSourceStreamIdleTimeout},
		{"gap exactly at threshold upgrades", cancelSourceClientClosed, cancelPhaseAfterFirstToken, streamIdleGapThresholdMs, cancelSourceStreamIdleTimeout},
		{"gap below threshold stays client_closed", cancelSourceClientClosed, cancelPhaseAfterFirstToken, 500, cancelSourceClientClosed},
		{"before_first_token never upgrades", cancelSourceClientClosed, cancelPhaseBeforeFirstToken, streamIdleGapThresholdMs + 1, cancelSourceClientClosed},
		{"provider_error source untouched", cancelSourceProviderError, cancelPhaseAfterFirstToken, streamIdleGapThresholdMs + 1, cancelSourceProviderError},
		{"speculative_loser untouched", cancelSourceSpeculativeLoser, cancelPhaseSpeculativeLoser, streamIdleGapThresholdMs + 1, cancelSourceSpeculativeLoser},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := refineCancelSourceForIdle(tc.source, tc.phase, tc.gapMs); got != tc.want {
				t.Errorf("refineCancelSourceForIdle(%q,%q,%v) = %q, want %q", tc.source, tc.phase, tc.gapMs, got, tc.want)
			}
		})
	}
}

// TestDeliveryMeasurementPopulatesOutcome verifies the relay delivery counters
// flow into the cancellation outcome via applyPendingRouteTelemetry.
func TestDeliveryMeasurementPopulatesOutcome(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-deliv", Attempt: 1}
	pr.RecordDeliveredChunk(40)
	pr.RecordDeliveredChunk(60)

	snap := pr.DeliverySnapshot()
	if snap.Chunks != 2 || snap.Bytes != 100 {
		t.Fatalf("DeliverySnapshot chunks=%d bytes=%d, want 2/100", snap.Chunks, snap.Bytes)
	}

	out := pendingRouteOutcome(pr, "partial_success", "no_terminal_after_cancel", 504)
	if out.CancelPhase != cancelPhaseAfterFirstToken {
		t.Fatalf("expected after_first_token phase, got %q", out.CancelPhase)
	}
	if out.ChunksSent != 2 || out.BytesSent != 100 || out.EstimatedDeliveredTokens != 2 {
		t.Fatalf("delivery fields not populated: chunks=%d bytes=%d est=%d", out.ChunksSent, out.BytesSent, out.EstimatedDeliveredTokens)
	}
	if out.LastChunkAtMs == 0 {
		t.Error("last_chunk_at_ms should be set after delivery")
	}
}

// TestSettledCancelUsesProviderExactDeliveredTokens verifies that for a settled
// after-commit cancellation the provider's exact delivered-token count (settled
// into usage.CompletionTokens by commit dc5a4136) is used as
// estimated_delivered_tokens, overriding the coordinator's content-frame estimate.
func TestSettledCancelUsesProviderExactDeliveredTokens(t *testing.T) {
	pr := &registry.PendingRequest{RequestID: "req-settle", Attempt: 1}
	pr.RecordDeliveredChunk(50) // relay frame estimate would be 2
	pr.RecordDeliveredChunk(50)

	out := completeRouteOutcome(pr, protocol.UsageInfo{PromptTokens: 12, CompletionTokens: 99, ReasoningTokens: 3}, 4200, true)
	if out.CancelPhase != cancelPhaseAfterProviderComplete || out.PartialSettlementStatus != partialSettlementSettled {
		t.Fatalf("expected settled after_provider_complete, got phase=%q settlement=%q", out.CancelPhase, out.PartialSettlementStatus)
	}
	if out.EstimatedDeliveredTokens != 99 {
		t.Fatalf("expected exact provider delivered tokens 99, got %d (frame estimate leaked?)", out.EstimatedDeliveredTokens)
	}
	if out.SettledPartialTokens != 99 || out.SettledPartialMicroUSD != 4200 || !out.ProviderTerminalReceived {
		t.Fatalf("settled fields wrong: tokens=%d usd=%d terminalRecv=%v", out.SettledPartialTokens, out.SettledPartialMicroUSD, out.ProviderTerminalReceived)
	}
}
