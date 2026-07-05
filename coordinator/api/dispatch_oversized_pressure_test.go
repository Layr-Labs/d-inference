package api

// DAR-347 follow-ups: the dispatch-time "stop the storm" logic must NOT turn a
// memory-pressured provider's ambiguous "batch token budget" rejection into a
// permanent fleet-wide 429 (#1), and a deterministic verdict observed from a
// speculative race LOSER must survive even when the surviving racer reports a
// transient/timeout error (#2).

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	// Unknown budget + unknown context → a "batch token budget" string is deterministic.
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		Error: "token_budget_exhausted: request exceeds batch token budget",
	})
	if !d.unservable || d.unservableReason != rejectionReasonOversized {
		t.Fatalf("deterministic loser must latch unservable; got unservable=%v reason=%q", d.unservable, d.unservableReason)
	}
}

// TestLatchDeterministicLoser_IgnoresTransient (DAR-347 #2): a transient-capacity
// loser must NOT latch — failover to a healthier provider must still happen.
func TestLatchDeterministicLoser_IgnoresTransient(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{Error: "request rejected: queue full"})
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
		Error: "token_budget_exhausted: request exceeds batch token budget",
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
