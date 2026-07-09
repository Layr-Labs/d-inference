package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Guard: PR #524 (byte-aware pooled ModelCapacitySnapshot) and PR #526
// (per-model version-floor gating) both edit ModelCapacitySnapshot; this pins
// that they compose — below-floor boxes dropped AND byte-aware pooled remaining.
func TestModelCapacitySnapshotFlooredByteModeComposition(t *testing.T) {
	reg := New(testLogger())
	reg.SetModelVersionFloors(ParseModelVersionFloors("gemma-4=0.7.5"))

	// Below-floor box (0.7.4) serving ONLY the floored model, with a large solo
	// token budget: if the floor gate regressed it would surface as a second
	// routable gemma provider AND add ~50k of remaining budget to the aggregate.
	old := makeSchedulerProvider(t, reg, "old-box", gemmaBuild, 30)
	old.mu.Lock()
	old.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 50_000
	old.mu.Unlock()
	setProviderVersion(old, "0.7.4")

	// At-floor box (0.7.5): mixed-KV byte pool shared by the floored big-KV model
	// (gemma, 100 kB/token → 10k-token view) and an unfloored small-KV co-resident
	// (gpt-oss, 10 kB/token → 100k-token view), both over the SAME 1 GB pool.
	newp := makeSchedulerProvider(t, reg, "new-box", gemmaBuild, 93)
	addAdvertisedModel(newp, gptossBuild)
	newp.mu.Lock()
	newp.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 10_000
	newp.BackendCapacity.Slots[0].KVBytesPerToken = 100_000
	newp.BackendCapacity.Slots = append(newp.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gptossBuild,
		State:                "running",
		ActiveTokenBudgetMax: 100_000,
		KVBytesPerToken:      10_000,
	})
	newp.mu.Unlock()
	setProviderVersion(newp, "0.7.5")

	// Burst gpt-oss on new-box (old-box does not serve it, so every reservation
	// lands here): nine × 10k tokens = 90k tokens = 0.9 GB pending inside one
	// heartbeat gap, leaving 0.1 GB of the shared 1 GB pool.
	for i := 0; i < 9; i++ {
		if got := reg.ReserveProvider(gptossBuild, &PendingRequest{
			RequestID: fmt.Sprintf("burst-%d", i), Model: gptossBuild, EstimatedPromptTokens: 500, RequestedMaxTokens: 9_500,
		}); got == nil {
			t.Fatalf("burst request %d rejected; 0.9 GB must fit the 1 GB pool", i)
		}
	}

	gemma := findModelCapacity(reg.ModelCapacitySnapshot(), gemmaBuild)
	if gemma == nil {
		t.Fatalf("gemma missing from capacity snapshot (the at-floor box should still count)")
	}
	// Floor property: only the at-floor box counts; the 0.7.4 box is dropped.
	if gemma.RoutableProviders != 1 {
		t.Fatalf("gemma RoutableProviders = %d, want 1 (only the >=0.7.5 box; the below-floor box must be dropped)", gemma.RoutableProviders)
	}
	// Byte + floor together: 0.1 GB byte headroom on the at-floor box ÷
	// 100 kB/token = 1_000 gemma tokens. Token-mode accounting over-advertises
	// (~10k on new-box alone); a leaked below-floor box adds its 50k solo budget
	// (~51k total). Only byte-aware per-model remaining on the floor-included box
	// alone yields exactly 1_000.
	if gemma.TokenBudgetRemaining != 1_000 {
		t.Fatalf("gemma token_budget_remaining = %d, want 1_000 (0.1 GB byte headroom on the at-floor box only)", gemma.TokenBudgetRemaining)
	}
}
