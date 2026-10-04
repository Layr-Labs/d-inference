package registry_test

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/candidatearena"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

type arenaTestCandidate struct {
	costMs   float64
	provider *production.Provider
	snapshot struct{ model string }
}

func TestScanPoolCandidatesAreIndependentValues(t *testing.T) {
	var planner *production.ReservationPlanner
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		Reservations: func(actual *production.ReservationPlanner) production.ReservationPreparation {
			planner = actual
			return actual
		},
	})
	const model = "arena-model"
	registered := make(map[string]*production.Provider)
	for i := 0; i < 3*candidatearena.ChunkSize+5; i++ {
		p := makeSchedulerProvider(t, reg, fmt.Sprintf("p-%03d", i), model, 50+float64(i%9))
		registered[p.ID] = p
	}
	scan := func() production.CandidateScan {
		pr := &production.PendingRequest{RequestID: "arena", Model: model, RequestedMaxTokens: 16}
		return planner.ScanCandidates(model, pr, false)
	}
	first := scan()
	if len(first.Candidates) != 3*candidatearena.ChunkSize+5 {
		t.Fatalf("pool size = %d, want %d", len(first.Candidates), 3*candidatearena.ChunkSize+5)
	}
	seen := make(map[*production.Candidate]struct{}, len(first.Candidates))
	providers := make(map[string]struct{}, len(first.Candidates))
	for _, c := range first.Candidates {
		if _, dup := seen[c]; dup {
			t.Fatal("pool entries alias the same arena slot")
		}
		seen[c] = struct{}{}
		p := registered[c.ProviderID]
		if p == nil || c.CandidateBinding != c.Quote().CandidateBinding || c.CandidateBinding != production.BindCandidate(p, model) {
			t.Fatalf("candidate/snapshot mismatch: %+v", c)
		}
		if _, dup := providers[c.ProviderID]; dup {
			t.Fatalf("provider %s appears twice in the pool", c.ProviderID)
		}
		providers[c.ProviderID] = struct{}{}
	}
	costs := make(map[*production.Candidate]float64, len(first.Candidates))
	for _, c := range first.Candidates {
		costs[c] = c.Quote().CostMs
	}
	second := scan()
	if len(second.Candidates) != len(first.Candidates) {
		t.Fatalf("second scan pool size = %d, want %d", len(second.Candidates), len(first.Candidates))
	}
	for _, c := range first.Candidates {
		if c.Quote().CostMs != costs[c] {
			t.Fatal("a second scan mutated the first scan's retained candidates")
		}
	}
}

// Every kept slot remains stable across the original five-chunk workload.
func TestCandidateArenaPointersStayValidAcrossChunks(t *testing.T) {
	var arena candidatearena.Arena[arenaTestCandidate]
	const n = 5*candidatearena.ChunkSize + 3
	kept := make([]*arenaTestCandidate, 0, n)
	for i := 0; i < n; i++ {
		c := arena.Next()
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

func TestCandidateArenaReleaseReusesAndZeroes(t *testing.T) {
	var arena candidatearena.Arena[arenaTestCandidate]
	a := arena.Next()
	a.costMs = 42
	arena.Release(a)
	b := arena.Next()
	if b != a {
		t.Fatal("release did not hand the slot back for reuse")
	}
	if b.costMs != 0 {
		t.Fatalf("reused slot not zeroed: costMs=%v", b.costMs)
	}
	b.costMs = 7
	c := arena.Next()
	arena.Release(b)
	if arena.Next() == b {
		t.Fatal("releasing a kept (non-latest) slot reclaimed it")
	}
	if b.costMs != 7 {
		t.Fatal("kept slot was disturbed")
	}
	_ = c
}
