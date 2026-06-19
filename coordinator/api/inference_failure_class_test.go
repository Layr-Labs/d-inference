package api

import "testing"

// TestIsUnservableProviderError pins the capacity-class provider-rejection
// classifier: ADMITTED-but-unservable conditions (token budget / KV-cache
// headroom / context overflow / OOM) are true; genuine faults and unrelated
// strings are false. Matching is substring + case-insensitive, and the short
// "oom" token must match only on word boundaries (not "boom"/"room").
func TestIsUnservableProviderError(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want bool
	}{
		// Capacity-class provider rejections → unservable (true).
		{"token budget exhausted", "token_budget_exhausted: need 9000", true},
		{"kv cache headroom", "insufficient global kv cache headroom", true},
		{"insufficient memory mixed case", "Insufficient memory (10 GB free, need 14 GB)", true},
		{"gpu oom word boundary", "GPU OOM", true},
		{"context length overflow", "exceeds 8192 context length", true},
		{"context window overflow", "prompt exceeds model context window", true},

		// Genuine faults / unrelated strings → servable (false).
		{"empty", "", false},
		{"internal error", "internal error", false},
		{"provider disconnected", "provider disconnected", false},
		{"boom is not oom", "boom", false},
		{"room is not oom", "no room left on device", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isUnservableProviderError(tt.in); got != tt.want {
				t.Errorf("isUnservableProviderError(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}
