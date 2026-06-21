package api

import "testing"

// TestClassifyRejection pins the deterministic-vs-transient split that drives the
// dispatch loop's stop-or-failover decision (DAR-347). The exact provider strings
// come from the Swift scheduler (BatchSchedulerTypes / BatchScheduler):
//   - "request exceeds batch token budget"  → prompt > min(context, kv) → deterministic
//     ONLY when the rejecting provider's budget was NOT below the model context
//     (otherwise the binding term may have been this node's shrunk KV budget).
//   - "request exceeds active token budget" → this node's KV budget          → transient
//   - "request requires N tokens but only M available" → this node's KV budget → transient
func TestClassifyRejection(t *testing.T) {
	cases := []struct {
		name           string
		reason         string
		errStr         string
		providerBudget int64
		modelContext   int
		want           rejectionKind
	}{
		{
			name:   "batch_token_budget_is_deterministic",
			errStr: "token_budget_exhausted: request exceeds batch token budget",
			want:   rejectionDeterministicUnservable,
		},
		{
			name:   "exceeds_context_window_is_deterministic",
			errStr: "prompt exceeds the model's context window",
			want:   rejectionDeterministicUnservable,
		},
		// Past-tense / marker-only context-overflow phrasings are deterministic too
		// (the deterministic check matches both "exceeds"/"exceeded" and the bare
		// context length/window markers).
		{
			name:   "context_length_exceeded_past_tense_is_deterministic",
			errStr: "context length exceeded",
			want:   rejectionDeterministicUnservable,
		},
		{
			name:   "context_window_exceeded_past_tense_is_deterministic",
			errStr: "context window exceeded",
			want:   rejectionDeterministicUnservable,
		},
		{
			name:   "too_long_for_context_window_is_deterministic",
			errStr: "prompt too long for context window",
			want:   rejectionDeterministicUnservable,
		},
		{
			name:   "active_token_budget_is_transient",
			errStr: "token_budget_exhausted: request exceeds active token budget",
			want:   rejectionTransientCapacity,
		},
		{
			name:   "requires_N_but_M_available_is_transient",
			errStr: "token_budget_exhausted: request requires 115635 tokens but only 90000 available",
			want:   rejectionTransientCapacity,
		},
		{
			name:   "insufficient_kv_headroom_is_transient",
			errStr: "token_budget_exhausted: insufficient global KV cache headroom",
			want:   rejectionTransientCapacity,
		},
		{name: "queue_full_is_transient", errStr: "request rejected: queue full", want: rejectionTransientCapacity},
		{name: "server_busy_is_transient", errStr: "server busy", want: rejectionTransientCapacity},
		{name: "draining_is_transient", errStr: "provider draining for update", want: rejectionTransientCapacity},
		{name: "not_loaded_is_transient", errStr: "model not loaded on this provider", want: rejectionTransientCapacity},
		{
			name:   "structured_reason_only_no_detail_is_transient",
			reason: "token_budget_exhausted",
			errStr: "",
			want:   rejectionTransientCapacity,
		},
		{
			name:   "reason_carries_batch_detail_is_deterministic",
			reason: "token_budget_exhausted",
			errStr: "request exceeds batch token budget",
			want:   rejectionDeterministicUnservable,
		},
		// DAR-347 #1: a "batch token budget" rejection is rejected at
		// min(context, activeTokenBudget). When the rejecting provider's reported
		// budget is KNOWN and BELOW the model context, it was memory-pressured, so
		// the binding term may have been THIS node's shrunk KV budget — a healthier
		// provider may serve. Treat as transient (failover), NOT deterministic-stop.
		{
			name:           "batch_budget_pressured_provider_is_transient",
			errStr:         "token_budget_exhausted: request exceeds batch token budget",
			providerBudget: 50_000,
			modelContext:   131072,
			want:           rejectionTransientCapacity,
		},
		// Budget >= context: the binding term was the context, identical fleet-wide.
		{
			name:           "batch_budget_unpressured_provider_is_deterministic",
			errStr:         "token_budget_exhausted: request exceeds batch token budget",
			providerBudget: 200_000,
			modelContext:   131072,
			want:           rejectionDeterministicUnservable,
		},
		// Budget known but context unknown: can't prove pressure ⇒ deterministic
		// (preserves the storm-stop default when context is unavailable).
		{
			name:           "batch_budget_unknown_context_is_deterministic",
			errStr:         "token_budget_exhausted: request exceeds batch token budget",
			providerBudget: 50_000,
			modelContext:   0,
			want:           rejectionDeterministicUnservable,
		},
		// Context known but provider budget unknown (no heartbeat budget): can't
		// prove pressure ⇒ deterministic.
		{
			name:           "batch_budget_unknown_budget_is_deterministic",
			errStr:         "token_budget_exhausted: request exceeds batch token budget",
			providerBudget: 0,
			modelContext:   131072,
			want:           rejectionDeterministicUnservable,
		},
		// An explicit "exceeds … context" phrasing names the context directly, so it
		// is deterministic regardless of the provider's (here pressured) budget.
		{
			name:           "explicit_context_overflow_ignores_budget",
			errStr:         "prompt exceeds the model's context window",
			providerBudget: 50_000,
			modelContext:   131072,
			want:           rejectionDeterministicUnservable,
		},
		// Genuine faults / unknown ⇒ not capacity (keep fault failover + breaker).
		{name: "crash_is_not_capacity", errStr: "backend crash during generation", want: rejectionNotCapacity},
		{name: "panic_is_not_capacity", errStr: "panic: nil map", want: rejectionNotCapacity},
		{name: "first_chunk_timeout_is_not_capacity", errStr: "timeout waiting for first response", want: rejectionNotCapacity},
		{name: "empty_is_not_capacity", errStr: "", want: rejectionNotCapacity},
		{name: "model_load_failed_bad_weights_is_not_capacity", errStr: "model load failed: bad metallib", want: rejectionNotCapacity},
		// A cold-load CAPACITY failure ("model load failed: insufficient memory") is
		// capacity-class but not deterministic-context ⇒ transient (failover may hit
		// a warmer/bigger node).
		{name: "model_load_failed_oom_is_transient", errStr: "model load failed: insufficient memory", want: rejectionTransientCapacity},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyRejection(tc.reason, tc.errStr, tc.providerBudget, tc.modelContext); got != tc.want {
				t.Errorf("classifyRejection(%q, %q, budget=%d, ctx=%d) = %d, want %d",
					tc.reason, tc.errStr, tc.providerBudget, tc.modelContext, got, tc.want)
			}
		})
	}
}
