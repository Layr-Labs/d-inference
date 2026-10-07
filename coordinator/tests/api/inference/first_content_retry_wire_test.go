package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func TestFirstContentThirdDispatchNeedsFreshQuote(t *testing.T) {
	reg, st, _, ts := setupTTFTFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "fresh-quote-retry-model"
	var attempts deadlineAttemptRecorder
	probeBudgets := make(chan int64, 8)
	quoteScript := func(ctx context.Context, fp *failoverProvider, probe protocol.CapacityProbeMessage) {
		confidence := protocol.CapacityConfidenceLow
		if len(attempts.snapshot()) >= 2 {
			confidence = protocol.CapacityConfidenceHigh
		}
		probeBudgets <- probe.DeadlineRemainingMS
		data, _ := json.Marshal(protocol.CapacityQuoteMessage{
			Type: protocol.TypeCapacityQuote, QuoteID: probe.QuoteID,
			CapacitySeq: 2, AdmissibleNow: true, Confidence: confidence,
			TTFTP50MS: 20, TTFTP90MS: 40, AvailableTokenBudget: 100_000,
		})
		if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Errorf("quote write: %v", err)
		}
	}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if len(body) == 0 {
			t.Error("provider did not receive encrypted request content")
		}
		if attempts.capture(t, reg, fp, req) <= 2 {
			time.Sleep(25 * time.Millisecond)
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, failure.ErrorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
			return
		}
		pr := reg.GetProvider(fp.registryID).GetPending(req.RequestID)
		if pr == nil || !pr.RequireFreshFeasible || pr.RequireFreshFeasibleAfter.IsZero() {
			t.Error("third dispatch bypassed fresh evidence requirement")
		}
		fp.serveFull(ctx, req, model, "FRESH_QUOTE_OK")
	}
	for i := range 3 {
		fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("fresh-quote-%d", i), Version: "0.8.15", DecodeTPS: 200,
			Models: []failoverModelSpec{{ID: model}}, Script: script, QuoteScript: quoteScript,
		})
		reportIdleFirstContentEvidence(reg, fp.registryID, model)
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "FRESH_QUOTE_OK") {
		t.Fatalf("fresh quote retry: status=%d err=%v body=%s attempts=%+v", status, err, body, attempts.snapshot())
	}
	got := attempts.snapshot()
	if len(got) != 3 || got[0].provider == got[1].provider || got[0].provider == got[2].provider || got[1].provider == got[2].provider {
		t.Fatalf("dispatches=%+v, want three distinct providers", got)
	}
	for i := 1; i < len(got); i++ {
		if got[i].wireMS >= got[i-1].wireMS {
			t.Fatalf("request deadline reset: %+v", got)
		}
	}
	if len(probeBudgets) == 0 || len(probeBudgets) > 4 {
		t.Fatalf("probe count=%d, want bounded initial/refresh rounds", len(probeBudgets))
	}
	for len(probeBudgets) > 0 {
		if budget := <-probeBudgets; budget <= 0 || budget > got[0].wireMS {
			t.Fatalf("probe budget=%d, initial wire=%d", budget, got[0].wireMS)
		}
	}
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	if outcome.Termination != "completed" {
		t.Fatalf("once-per-request accounting: %+v", outcome)
	}
}

func TestFirstContentRetryCannotLaunchSecondHedge(t *testing.T) {
	reg, st, _, ts := setupTTFTFailoverServerWithConfig(t, TestServerConfig{FirstContentDeadlineBase: 3 * time.Second})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const model = "one-hedge-per-request"
	var attempts dispatchRecorder
	quoteScript := func(ctx context.Context, fp *failoverProvider, probe protocol.CapacityProbeMessage) {
		data, _ := json.Marshal(protocol.CapacityQuoteMessage{
			Type: protocol.TypeCapacityQuote, QuoteID: probe.QuoteID,
			CapacitySeq: 2, AdmissibleNow: true, Confidence: protocol.CapacityConfidenceHigh,
			TTFTP50MS: 20, TTFTP90MS: 40, AvailableTokenBudget: 100_000,
		})
		if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Errorf("quote write: %v", err)
		}
	}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		switch attempts.record(fp.name) {
		case 1:
			fp.sendAccepted(ctx, req)
			time.Sleep(1700 * time.Millisecond)
			fp.sendInferenceError(ctx, req, "primary fault", http.StatusInternalServerError)
		case 2:
			fp.sendInferenceError(ctx, req, "hedge fault", http.StatusInternalServerError)
		case 3:
			fp.sendAccepted(ctx, req)
			time.Sleep(300 * time.Millisecond)
			fp.serveFull(ctx, req, model, "ONE_HEDGE_OK")
		default:
			t.Error("logical retry launched a second hedge")
			fp.serveFull(ctx, req, model, "UNEXPECTED_HEDGE")
		}
	}
	for i := range 4 {
		fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("one-hedge-%d", i), Version: "0.8.15", DecodeTPS: 200,
			Models: []failoverModelSpec{{ID: model}}, Script: script, QuoteScript: quoteScript,
		})
		reportIdleFirstContentEvidence(reg, fp.registryID, model)
	}
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil || status != http.StatusOK || !strings.Contains(body, "ONE_HEDGE_OK") {
		t.Fatalf("single hedge retry: status=%d err=%v body=%s attempts=%v", status, err, body, attempts.sequence())
	}
	if got := attempts.sequence(); len(got) != 3 {
		t.Fatalf("attempts=%v, want primary, one hedge, retry", got)
	}
	outcome := awaitRequestOutcomes(t, st, 1)[0]
	backups := 0
	for _, attempt := range outcome.Attempts {
		if attempt.BackupOf != "" && attempt.WriteCompleted {
			backups++
		}
	}
	if backups != 1 || outcome.Termination != "completed" {
		t.Fatalf("single hedge terminal accounting: %+v", outcome)
	}
}
