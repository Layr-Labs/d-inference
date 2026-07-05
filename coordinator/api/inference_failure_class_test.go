package api

import "testing"

// TestIsCapacityClassProviderError pins the capacity-vs-fault split.
//
// BUCKET A (capacity/lifecycle) → true: the provider admitted/attempted the
// request then rejected it for a capacity reason (token budget / KV-cache /
// context overflow / OOM / slot cap / update drain / overload backpressure /
// cold "not loaded" miss). These reclassify a 5xx to an uptime-neutral 429.
//
// BUCKET B (genuine fault) → false: crashes/panics, internal/backend failures,
// "model load failed" (bad weights/metallib), and the opaque Foundation string
// stay 5xx. The default for unknown/ambiguous strings is also false (fault) so
// crashes stay visible. Matching is substring + case-insensitive, and the short
// "oom" token must match only on word boundaries (not "boom"/"room").
func TestIsCapacityClassProviderError(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want bool
	}{
		// --- BUCKET A: capacity-class provider rejections → true. ---
		// Existing markers (no-regression).
		{"token budget exhausted", "token_budget_exhausted: need 9000", true},
		{"kv cache headroom", "insufficient global kv cache headroom", true},
		{"insufficient memory mixed case", "Insufficient memory (10 GB free, need 14 GB)", true},
		{"gpu oom word boundary", "GPU OOM", true},
		{"context length overflow", "exceeds 8192 context length", true},
		{"context window overflow", "prompt exceeds model context window", true},
		// New markers / phrasings.
		{"kv headroom real string", "insufficient global KV cache headroom", true},
		{"queue timeout capacity", "request timed out waiting for capacity", true},
		{"insufficient memory at load", "insufficient memory to load model 'X'", true},
		{"token budget with detail", "token_budget_exhausted: request requires 5000 tokens but only 100 available", true},
		{"slot cap active", "All 3 model slot(s) are active; cannot load 'X'", true},
		{"provider draining for update", "provider draining for update", true},
		{"request rejected backpressure", "request rejected", true},
		{"server busy backpressure", "server busy", true},
		{"queue full backpressure", "token_budget_exhausted: request queue full", true},
		{"cold model not loaded", "Model 'X' is not loaded on this provider", true},
		// "model load failed: <capacity reason>" — a transient cold-load capacity
		// failure must reclassify to 429 (capacity wins over the load-fail wrapper).
		{"load failed insufficient memory", "model load failed: insufficient memory to load model 'X'", true},
		{"load failed insufficient kv", "model load failed: insufficient KV headroom for 'X'", true},
		{"load failed slot cap", "model load failed: all 3 model slot(s) are active", true},

		// --- BUCKET B: genuine faults / unrelated strings → false. ---
		// Existing cases (no-regression).
		{"empty", "", false},
		{"internal error", "internal error", false},
		{"provider disconnected", "provider disconnected", false},
		// Coordinator-generated 503 (e.g. a failed reservation top-up in the
		// dispatch path emits "service temporarily unavailable — please retry")
		// must stay a fault — NOT be hidden as an uptime-neutral 429 — because it
		// is the coordinator's own failure, not provider capacity backpressure.
		{"coordinator service unavailable stays fault", "service temporarily unavailable — please retry", false},
		{"boom is not oom", "boom", false},
		{"room is not oom", "no room left on device", false},
		// New fault cases.
		{"foundation opaque string", "The operation couldn't be completed. (ProviderCore.InferenceError error 0.)", false},
		// Ordering-bug guard: "model load failed" MUST stay a fault even though
		// the capacity bucket matches "not loaded" / "loaded"-shaped strings.
		{"model load failed bad weights", "model load failed: invalid weights", false},
		{"model load failed opaque", "model load failed: the operation couldn't be completed.", false},
		{"panic crash", "panic: runtime error: index out of range", false},
		{"fatal error crash", "fatal error: unexpectedly found nil", false},
		{"backend crash", "backend_crash: engine exited", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isCapacityClassProviderError(tt.in); got != tt.want {
				t.Errorf("isCapacityClassProviderError(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}
