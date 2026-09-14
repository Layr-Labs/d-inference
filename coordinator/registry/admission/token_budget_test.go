package admission

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestProviderTokenBudget pins the pooled-budget reconstruction. Each backend
// slot's ActiveTokenBudgetMax = (that slot's committed tokens) + the provider's
// SHARED KV headroom, so per-slot maxes are not additive: total must be Σ
// committed + the shared free headroom counted ONCE, and used must be Σ
// committed. used <= total must hold by construction.
func TestProviderTokenBudget(t *testing.T) {
	tests := []struct {
		name      string
		slots     []protocol.BackendSlotCapacity
		wantUsed  int64
		wantTotal int64
	}{
		{
			name:      "nil slots",
			slots:     nil,
			wantUsed:  0,
			wantTotal: 0,
		},
		{
			name:      "empty slots",
			slots:     []protocol.BackendSlotCapacity{},
			wantUsed:  0,
			wantTotal: 0,
		},
		{
			name: "single slot reduces to old value",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 7000},
			},
			wantUsed:  7000,
			wantTotal: 10000,
		},
		{
			name: "single slot counts queued as committed",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 5000, QueuedTokenBudget: 2000},
			},
			wantUsed:  7000,
			wantTotal: 10000,
		},
		{
			name: "two slots share one headroom pool",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 7000},
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 7000},
			},
			// committed 14000 + shared free 3000 (counted once) = 17000.
			wantUsed:  14000,
			wantTotal: 17000,
		},
		{
			name: "over-committed single slot floors free at zero",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 11000},
			},
			wantUsed:  11000,
			wantTotal: 11000,
		},
		{
			name: "static-bound mix takes max shared free",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 8000},
				{ActiveTokenBudgetMax: 5000, ActiveTokenBudgetUsed: 3000},
			},
			// committed 11000 + max(2000, 2000) = 13000.
			wantUsed:  11000,
			wantTotal: 13000,
		},
		{
			name: "slot with zero max is ignored",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 0, ActiveTokenBudgetUsed: 5000, QueuedTokenBudget: 9000},
			},
			wantUsed:  0,
			wantTotal: 0,
		},
		{
			name: "slot with negative max is ignored alongside a valid slot",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: 7000},
				{ActiveTokenBudgetMax: -1, ActiveTokenBudgetUsed: 9000, QueuedTokenBudget: 9000},
			},
			wantUsed:  7000,
			wantTotal: 10000,
		},
		{
			name: "negative committed is floored at zero",
			slots: []protocol.BackendSlotCapacity{
				{ActiveTokenBudgetMax: 10000, ActiveTokenBudgetUsed: -500},
			},
			wantUsed:  0,
			wantTotal: 10000,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			used, total := legacyTokenBudget(tt.slots)
			if used != tt.wantUsed || total != tt.wantTotal {
				t.Fatalf("legacyTokenBudget() = used %d, total %d; want used %d, total %d",
					used, total, tt.wantUsed, tt.wantTotal)
			}
			if used > total {
				t.Fatalf("invariant violated: used %d > total %d", used, total)
			}
		})
	}
}
