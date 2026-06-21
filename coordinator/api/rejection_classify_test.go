package api

import "testing"

// TestClassifyRejection pins the deterministic-vs-transient split that drives the
// dispatch loop's stop-or-failover decision (DAR-347). The exact provider strings
// come from the Swift scheduler (BatchSchedulerTypes / BatchScheduler):
//   - "request exceeds batch token budget"  → prompt > min(context, kv) ≈ context → deterministic
//   - "request exceeds active token budget" → this node's KV budget          → transient
//   - "request requires N tokens but only M available" → this node's KV budget → transient
func TestClassifyRejection(t *testing.T) {
	cases := []struct {
		name   string
		reason string
		errStr string
		want   rejectionKind
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
			if got := classifyRejection(tc.reason, tc.errStr); got != tc.want {
				t.Errorf("classifyRejection(%q, %q) = %d, want %d", tc.reason, tc.errStr, got, tc.want)
			}
		})
	}
}
