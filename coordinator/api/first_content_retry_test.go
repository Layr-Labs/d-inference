package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func TestPredictiveRefusalIsRequestLocalAndRequiresNewEvidence(t *testing.T) {
	d := &dispatchState{lastFailedVersion: "broken-for-another-request"}
	for _, id := range []string{"a", "a", "b"} {
		d.setLastInferenceError(&registry.Provider{ID: id}, protocol.InferenceErrorMessage{
			FailureCode: protocol.FailureCodeCapacity, ErrorReason: errorReasonDeadlineUnreachable,
			StatusCode: http.StatusServiceUnavailable,
		})
	}
	pr := &registry.PendingRequest{}
	d.configureFirstContentReservation(pr, false)
	if d.predictiveRefusals != 2 || !pr.RequireFreshFeasible || pr.RequireFreshFeasibleAfter.IsZero() {
		t.Fatalf("refusals=%d pending=%+v", d.predictiveRefusals, pr)
	}
	if len(d.excludeProviders) != 2 || d.traits().AvoidVersion != "" || d.genuineFault != nil {
		t.Fatal("predictive refusal did not remain request-local")
	}
}

func TestPredictiveRaceRefusalsRequireFreshEvidence(t *testing.T) {
	d, _, primary, primaryPR, backup, backupPR := speculativeFailureTestState(t, time.Second, 500*time.Millisecond)
	d.provider, d.pr, d.requestID = primary, primaryPR, primaryPR.RequestID
	primaryPR.ErrorCh <- deadlineUnreachableMessage()
	backupPR.ErrorCh <- deadlineUnreachableMessage()
	if got := d.runRace(backup, backupPR); got != outcomeRetry {
		t.Fatalf("race outcome=%v, want retry", got)
	}
	next := &registry.PendingRequest{}
	d.configureFirstContentReservation(next, false)
	if d.predictiveRefusals != 2 || !next.RequireFreshFeasible || next.RequireFreshFeasibleAfter.IsZero() {
		t.Fatalf("two refusing racers did not require fresh evidence: refusals=%d pending=%+v", d.predictiveRefusals, next)
	}
	for _, provider := range []*registry.Provider{primary, backup} {
		if _, excluded := d.excludeProviders[provider.ID]; !excluded {
			t.Fatalf("refusing racer %q was not excluded", provider.ID)
		}
		// Error observation through another race path cannot spend a second
		// refusal on the same provider or move the evidence cutoff again.
		d.latchDeterministicLoser(provider, deadlineUnreachableMessage())
	}
	if d.predictiveRefusals != 2 || !d.freshFeasibleAfter.Equal(next.RequireFreshFeasibleAfter) {
		t.Fatal("duplicate loser observation counted another refusal")
	}
	if d.genuineFault != nil || d.unservable || d.terminalClientError || d.traits().AvoidVersion != "" {
		t.Fatal("predictive race refusal became a sticky fault or version penalty")
	}
}

func TestFirstContentQuoteShapeSurvivesPlannerInvalidation(t *testing.T) {
	d := &dispatchState{model: "gpt-oss-20b", estimatedPromptTokens: 1000,
		cachePlan: registry.CachePlan{PromptTokenCount: 800}}
	if got := d.firstContentPromptWork(); got != 1300 {
		t.Fatalf("probe work=%d, want calibrated fallback envelope", got)
	}
	d.cachePlan.PromptTokenCount = 2000
	if got := d.firstContentPromptWork(); got != 2000 {
		t.Fatalf("probe work=%d, want larger exact prompt count", got)
	}
}

func TestExemptHedgeAdvisoryForecastDoesNotInstallDeadline(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "exempt-hedge-forecast"
	provider := planWiringProvider(t, s.registry, "exempt-spare", model, 0)
	reportIdleFirstContentEvidence(s.registry, provider.ID, model)
	d := &dispatchState{model: model, estimatedPromptTokens: 500}
	pr := &registry.PendingRequest{RequestID: "exempt-hedge", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 64}
	d.configureFirstContentReservation(pr, true)
	winner, decision := s.registry.ReserveProviderEx(model, pr)
	if winner == nil || decision.FirstContent.Status != registry.FirstContentFeasible {
		t.Fatalf("credible exempt hedge unavailable: %+v", decision)
	}
	defer winner.RemovePending(pr.RequestID)
	if !pr.FirstContentDeadline.IsZero() || pr.MaxTTFTMs != 0 || !pr.RefreshFirstContentBudget(time.Now().Add(time.Hour)) {
		t.Fatal("advisory forecast installed a deadline on an exempt request")
	}
}

func TestExemptPredictiveRetryCanRecoverWithoutInstallingDeadline(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "exempt-predictive-retry"
	provider := planWiringProvider(t, s.registry, "exempt-fresh", model, 0)
	d := &dispatchState{model: model, estimatedPromptTokens: 500}
	ordinary := &registry.PendingRequest{RequestID: "ordinary", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 64}
	d.configureFirstContentReservation(ordinary, false)
	if ordinary.FirstContentPlanningHorizon != 0 {
		t.Fatal("ordinary exempt primary acquired an advisory horizon")
	}
	d.notePredictiveRefusal(&registry.Provider{ID: "refused-a"})
	d.notePredictiveRefusal(&registry.Provider{ID: "refused-b"})
	reportIdleFirstContentEvidence(s.registry, provider.ID, model)
	pr := &registry.PendingRequest{RequestID: "exempt-retry", Model: model,
		EstimatedPromptTokens: 500, RequestedMaxTokens: 64}
	d.configureFirstContentReservation(pr, false)
	winner, decision := s.registry.ReserveProviderEx(model, pr)
	if winner == nil || decision.FirstContent.Status != registry.FirstContentFeasible || pr.Hedge {
		t.Fatalf("fresh exempt retry unavailable: %+v", decision)
	}
	defer winner.RemovePending(pr.RequestID)
	if !pr.FirstContentDeadline.IsZero() || pr.MaxTTFTMs != 0 || !pr.RefreshFirstContentBudget(time.Now().Add(time.Hour)) {
		t.Fatal("advisory retry forecast installed a deadline on an exempt request")
	}
}

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
			fp.sendTypedInferenceError(ctx, req, protocol.FailureCodeCapacity, errorReasonDeadlineUnreachable, http.StatusServiceUnavailable)
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

func TestFirstContentDoesNotWaitForUnforecastableCapacity(t *testing.T) {
	d, _ := firstTokenWaitState(t, 0, time.Second)
	d.w = httptest.NewRecorder()
	refunds := 0
	d.refundReservation = func() { refunds++ }
	if !d.rejectUnforecastableCapacityWait(registry.RoutingDecision{CapacityRejections: 1}) || refunds != 1 {
		t.Fatalf("unforecastable wait retained: refunds=%d", refunds)
	}
	for _, policy := range []selfRoutePolicy{{enabled: true}, {prefer: true}} {
		d.policy = policy
		if d.rejectUnforecastableCapacityWait(registry.RoutingDecision{CapacityRejections: 1}) {
			t.Fatal("owner-directed queue policy changed")
		}
	}
	d.policy, d.deadline = selfRoutePolicy{}, 0
	if d.rejectUnforecastableCapacityWait(registry.RoutingDecision{CapacityRejections: 1}) {
		t.Fatal("deadline-exempt queue policy changed")
	}
}

func TestFirstContentRetryCannotLaunchSecondHedge(t *testing.T) {
	reg, st, _, ts := setupTTFTFailoverServerWithConfig(t, ServerConfig{FirstContentDeadlineBase: 3 * time.Second})
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
