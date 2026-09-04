package registry

import (
	"fmt"
	"testing"
)

// TestCandidateArenaPointersStayValidAcrossChunks pins the arena's only
// hard guarantee: a slot handed out and kept is never moved, so pointers
// taken across many chunk boundaries keep reading the value written into them.
func TestCandidateArenaPointersStayValidAcrossChunks(t *testing.T) {
	var arena candidateArena
	const n = 5*candidateArenaChunk + 3
	kept := make([]*routingCandidate, 0, n)
	for i := 0; i < n; i++ {
		c := arena.next()
		if c.costMs != 0 || c.provider != nil || c.snapshot.model != "" {
			t.Fatalf("slot %d not zeroed: %+v", i, c)
		}
		c.costMs = float64(i)
		c.snapshot.model = fmt.Sprintf("m-%d", i)
		kept = append(kept, c)
	}
	for i, c := range kept {
		if c.costMs != float64(i) || c.snapshot.model != fmt.Sprintf("m-%d", i) {
			t.Fatalf("slot %d was overwritten or moved: %+v", i, c)
		}
	}
	for i := 1; i < len(kept); i++ {
		if kept[i] == kept[i-1] {
			t.Fatalf("slots %d and %d alias", i-1, i)
		}
	}
}

// TestCandidateArenaReleaseReusesAndZeroes pins the rejection path: the most
// recently handed-out slot is reused (no new chunk) and comes back zeroed;
// releasing anything else is a no-op so a kept slot is never reclaimed.
func TestCandidateArenaReleaseReusesAndZeroes(t *testing.T) {
	var arena candidateArena
	a := arena.next()
	a.costMs = 42
	arena.release(a)
	b := arena.next()
	if b != a {
		t.Fatal("release did not hand the slot back for reuse")
	}
	if b.costMs != 0 {
		t.Fatalf("reused slot not zeroed: costMs=%v", b.costMs)
	}
	b.costMs = 7
	c := arena.next()
	arena.release(b) // not the most recent slot: must be ignored
	if arena.next() == b {
		t.Fatal("releasing a kept (non-latest) slot reclaimed it")
	}
	if b.costMs != 7 {
		t.Fatal("kept slot was disturbed")
	}
	_ = c
}

// TestScanPoolCandidatesAreIndependentValues pins the scan-level contract the
// arena must preserve: every pool entry's snapshot belongs to its own
// provider, entries never alias, and a second scan does not disturb the first
// scan's retained candidates (the DispatchPlan keeps them).
func TestScanPoolCandidatesAreIndependentValues(t *testing.T) {
	reg := New(testLogger())
	const model = "arena-model"
	for i := 0; i < 3*candidateArenaChunk+5; i++ {
		makeSchedulerProvider(t, reg, fmt.Sprintf("p-%03d", i), model, 50+float64(i%9))
	}
	scan := func() candidateScan {
		pr := &PendingRequest{RequestID: "arena", Model: model, RequestedMaxTokens: 16}
		reg.mu.RLock()
		defer reg.mu.RUnlock()
		return reg.scanCandidatesLocked(model, pr, false)
	}
	first := scan()
	if len(first.pool) != 3*candidateArenaChunk+5 {
		t.Fatalf("pool size = %d, want %d", len(first.pool), 3*candidateArenaChunk+5)
	}
	seen := make(map[*routingCandidate]struct{}, len(first.pool))
	providers := make(map[string]struct{}, len(first.pool))
	for _, c := range first.pool {
		if _, dup := seen[c]; dup {
			t.Fatal("pool entries alias the same arena slot")
		}
		seen[c] = struct{}{}
		if c.provider == nil || c.snapshot.provider != c.provider || c.snapshot.model != model {
			t.Fatalf("candidate/snapshot mismatch: %+v", c)
		}
		if _, dup := providers[c.provider.ID]; dup {
			t.Fatalf("provider %s appears twice in the pool", c.provider.ID)
		}
		providers[c.provider.ID] = struct{}{}
	}
	costs := make(map[*routingCandidate]float64, len(first.pool))
	for _, c := range first.pool {
		costs[c] = c.costMs
	}
	second := scan()
	if len(second.pool) != len(first.pool) {
		t.Fatalf("second scan pool size = %d, want %d", len(second.pool), len(first.pool))
	}
	for _, c := range first.pool {
		if c.costMs != costs[c] {
			t.Fatal("a second scan mutated the first scan's retained candidates")
		}
	}
}
