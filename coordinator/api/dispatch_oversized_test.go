package api

// DAR-347 dispatch-loop integration tests: oversized / capacity rejections must
// stop the failover loop early (uptime-neutral 429) instead of storming all 64
// providers, while genuine transient-capacity rejections still fail over. They
// reuse the failover harness (setupFailoverServer / startFailoverProvider /
// postChat) and drive the REAL dispatch loop through fake WS providers.

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// rejectScript makes every dispatch reject pre-content with (errMsg, status) and
// NO chunks — the shape of a provider token-budget admission rejection.
func rejectScript(errMsg string, status int) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendInferenceError(ctx, req, errMsg, status)
	}
}

// TestDispatch_DeterministicTokenBudget_StopsAfterOneAttempt: a request whose
// prompt exceeds the model context is rejected identically by every provider
// ("request exceeds batch token budget"). The loop MUST stop after the first
// attempt and return an uptime-neutral 429 + Retry-After — not retry across the
// fleet (the prod storm: median 22 / max 63 attempts). Two providers are present
// so a storm would be observable as >1 dispatch.
func TestDispatch_DeterministicTokenBudget_StopsAfterOneAttempt(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "oversized-deterministic-model"
	script := rejectScript("token_budget_exhausted: request exceeds batch token budget", http.StatusServiceUnavailable)
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	// Inline request so we can assert the Retry-After header.
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions",
		strings.NewReader(buildChatBody(t, model, false, nil)))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	defer resp.Body.Close()
	bodyBytes, _ := io.ReadAll(resp.Body)
	body := string(bodyBytes)

	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (deterministic unservable → uptime-neutral 429); body=%s", resp.StatusCode, body)
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Errorf("missing Retry-After header on the 429")
	}
	if !strings.Contains(body, "rate_limit_exceeded") {
		t.Errorf("body missing rate_limit_exceeded code; body=%s", body)
	}
	if total := pA.dispatchCount() + pB.dispatchCount(); total != 1 {
		t.Errorf("total dispatches = %d, want 1 — a deterministic context rejection must STOP after the first attempt, not storm", total)
	}
}

// TestDispatch_TransientCapacity_StillFailsOver: a provider-specific transient
// shortage ("queue full") must NOT stop the loop — another provider may serve it.
// Guards against over-rejection (the false-NO / underutilization direction).
func TestDispatch_TransientCapacity_StillFailsOver(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "transient-capacity-model"
	rec := &dispatchRecorder{}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if rec.record(fp.name) == 1 {
			// First-dispatched provider: transient capacity shortage.
			fp.sendInferenceError(ctx, req, "request rejected: queue full", http.StatusServiceUnavailable)
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want 2 (transient capacity must fail over to a second provider); status=%d body=%s", seq, status, body)
	}
	if seq[0] == seq[1] {
		t.Errorf("both dispatches went to %q — failover must retry on a DIFFERENT provider", seq[0])
	}
	assertCleanFailoverStream(t, status, body, markerFor(seq[1]))
}

// TestDispatch_TransientCapacity_CappedRetries: when EVERY provider returns a
// transient capacity shortage, the loop must stop at maxCapacityClassRetries (not
// walk all maxDispatchAttempts=64). Five providers are present so the cap — not
// candidate exhaustion — is what stops it.
func TestDispatch_TransientCapacity_CappedRetries(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "transient-capped-model"
	script := rejectScript("server busy", http.StatusServiceUnavailable)
	const nProviders = 5
	providers := make([]*failoverProvider, 0, nProviders)
	for i := 0; i < nProviders; i++ {
		providers = append(providers, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name: fmt.Sprintf("provider-%d", i), Version: "0.6.20", DecodeTPS: 100,
			Models: []failoverModelSpec{{ID: model}}, Script: script,
		}))
	}

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429; body=%s", status, body)
	}
	total := 0
	for _, p := range providers {
		total += p.dispatchCount()
	}
	if total != maxCapacityClassRetries {
		t.Errorf("total dispatches = %d, want %d (transient capacity must be capped, not stormed to %d)",
			total, maxCapacityClassRetries, maxDispatchAttempts)
	}
}

// registerModelContext registers modelID in the store with a known context window
// so the dispatch path's modelMaxContext is populated (it reads
// store.GetModelRegistryRecord(model).MaxContextLength). The record is only
// returned when an active+ready version exists, so set+promote a minimal one.
func registerModelContext(t *testing.T, st *store.MemoryStore, modelID string, ctxLen int) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: modelID, DisplayName: modelID, Quantization: "4bit",
		MaxContextLength: ctxLen, MaxOutputLength: 8192, MinRAMGB: 8,
		Capabilities: []string{"chat"}, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: modelID, Version: "v1", R2Prefix: modelR2Prefix(modelID, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatalf("SetModelVersion: %v", err)
	}
	if err := st.PromoteModelVersion(modelID, "v1"); err != nil {
		t.Fatalf("PromoteModelVersion: %v", err)
	}
}

// setProviderModelBudget stamps a per-model reported token budget on a provider so
// the dispatch path can read it (ReportedTokenBudgetMaxForModel) when classifying a
// "batch token budget" rejection. Written under the provider mutex — the same lock
// the reader takes.
func setProviderModelBudget(t *testing.T, reg *registry.Registry, registryID, model string, budgetMax int64) {
	t.Helper()
	p := reg.GetProvider(registryID)
	if p == nil {
		t.Fatalf("provider %q missing", registryID)
	}
	p.Mu().Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{{
			Model: model, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: budgetMax,
		}},
	}
	p.Mu().Unlock()
}

// TestDispatch_BatchTokenBudget_PressuredProvider_FailsOver (DAR-347 #1): a
// "request exceeds batch token budget" rejection is NOT fleet-wide deterministic
// when the rejecting provider was memory-pressured. The provider's admission cap is
// min(context, activeTokenBudget); with a reported budget BELOW the model context,
// the binding term may have been this node's shrunk KV budget, so a healthier
// provider can still serve. The loop MUST fail over — not stop-at-1 and 429.
// Fails against the pre-fix code, which classified every batch-budget string as
// deterministic and stopped after the first provider.
func TestDispatch_BatchTokenBudget_PressuredProvider_FailsOver(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "pressured-batch-budget-model"
	const contextLen = 131072
	registerModelContext(t, st, model, contextLen)

	rec := &dispatchRecorder{}
	script := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if rec.record(fp.name) == 1 {
			// First-dispatched provider rejects with the ambiguous batch-budget string.
			fp.sendInferenceError(ctx, req, "token_budget_exhausted: request exceeds batch token budget", http.StatusServiceUnavailable)
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	// Both providers report a token budget BELOW the model context → memory-pressured,
	// so a batch-budget rejection is provider-specific (transient), not fleet-wide.
	setProviderModelBudget(t, reg, pA.registryID, model, 50_000)
	setProviderModelBudget(t, reg, pB.registryID, model, 50_000)

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	seq := rec.sequence()
	if len(seq) != 2 {
		t.Fatalf("dispatch sequence = %v, want 2 (a pressured batch-budget rejection must fail over, not stop-at-1); status=%d body=%s", seq, status, body)
	}
	if seq[0] == seq[1] {
		t.Errorf("both dispatches went to %q — failover must retry a DIFFERENT provider", seq[0])
	}
	assertCleanFailoverStream(t, status, body, markerFor(seq[1]))
}

// TestDispatch_BatchTokenBudget_UnpressuredProvider_StopsAtOne (DAR-347 #1
// counter-case): when the rejecting provider's reported budget is at/above the
// model context, the batch-budget rejection IS fleet-wide deterministic — the
// storm-stop must still fire (one dispatch, uptime-neutral 429). Guards against the
// budget-aware path accidentally downgrading genuine oversize to failover.
func TestDispatch_BatchTokenBudget_UnpressuredProvider_StopsAtOne(t *testing.T) {
	reg, st, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	const model = "unpressured-batch-budget-model"
	const contextLen = 131072
	registerModelContext(t, st, model, contextLen)

	script := rejectScript("token_budget_exhausted: request exceeds batch token budget", http.StatusServiceUnavailable)
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.20", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.20", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: script,
	})
	// Budgets at/above the model context → the binding term is the context, so the
	// rejection is identical on every provider.
	setProviderModelBudget(t, reg, pA.registryID, model, 200_000)
	setProviderModelBudget(t, reg, pB.registryID, model, 200_000)

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, false, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (deterministic oversize → uptime-neutral 429); body=%s", status, body)
	}
	if total := pA.dispatchCount() + pB.dispatchCount(); total != 1 {
		t.Errorf("total dispatches = %d, want 1 — a context-bound oversize must STOP after the first attempt", total)
	}
}

// newTestServerForDispatch builds a minimal Server for unit-testing dispatchState
// helpers that only need s.ddIncr (nil-safe) and s.model.
func newTestServerForDispatch(t *testing.T) *Server {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	return NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
}

// TestLatchDeterministicLoser_Latches (DAR-347 #2): a deterministic-unservable
// rejection from a speculative race loser sets d.unservable even though the loser's
// error is never written to d.lastErr (the surviving racer owns that).
func TestLatchDeterministicLoser_Latches(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	// Unknown budget + unknown context → the bounded batch-budget reason is deterministic.
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: errorReasonRequestExceedsBatchBudget,
	})
	if !d.unservable || d.unservableReason != rejectionReasonOversized {
		t.Fatalf("deterministic loser must latch unservable; got unservable=%v reason=%q", d.unservable, d.unservableReason)
	}
}

// TestLatchDeterministicLoser_IgnoresTransient (DAR-347 #2): a transient-capacity
// loser must NOT latch — failover to a healthier provider must still happen.
func TestLatchDeterministicLoser_IgnoresTransient(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: errorReasonQueueFull,
	})
	if d.unservable {
		t.Fatalf("a transient loser must NOT latch unservable (it would block legitimate failover)")
	}
}

// TestLatchDeterministicLoser_PressuredBatchBudgetNotLatched (DAR-347 #1 ∩ #2):
// the loser latch is budget-aware. A memory-pressured loser's "batch token budget"
// (reported budget below the model context) must NOT latch, so the race can still
// fail over to a healthier provider.
func TestLatchDeterministicLoser_PressuredBatchBudgetNotLatched(t *testing.T) {
	p := &registry.Provider{BackendCapacity: &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "running", ActiveTokenBudgetMax: 50_000}},
	}}
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", modelMaxContext: 131072}
	d.latchDeterministicLoser(p, protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: errorReasonRequestExceedsBatchBudget,
	})
	if d.unservable {
		t.Fatalf("a pressured (budget<context) batch-budget loser must NOT latch unservable")
	}
}

// TestShouldStopFailover_HonorsLatch (DAR-347 #2): once a deterministic loser has
// latched d.unservable, shouldStopFailover stops at the next retry point regardless
// of the surviving racer's (here transient) lastErr — the exact gap that let the
// speculative path keep storming. Fails without the d.unservable guard, which would
// classify "queue full" as a transient and keep failing over.
func TestShouldStopFailover_HonorsLatch(t *testing.T) {
	d := &dispatchState{
		s: newTestServerForDispatch(t), model: "m",
		unservable: true, unservableReason: rejectionReasonOversized,
		lastErr: "request rejected: queue full", // a transient that alone would NOT stop failover
	}
	if !d.shouldStopFailover() {
		t.Fatalf("shouldStopFailover must honor a previously-latched unservable verdict")
	}
}
