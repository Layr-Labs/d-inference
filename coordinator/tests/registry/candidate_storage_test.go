package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/candidatearena"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Reset must clear the high-water mark, including rejected slots, when a later
// scan is smaller. Overflow belongs to the request and cannot enter the pool.
func TestCandidateStorageResetAndBound(t *testing.T) {
	var storage candidatearena.Storage[arenaTestCandidate]
	arena := candidatearena.Arena[arenaTestCandidate]{Storage: &storage}
	provider := &production.Provider{ID: "detached-reference"}
	slots := make([]*arenaTestCandidate, 0, candidatearena.MaxReusableCandidates)
	for i := 0; i < candidatearena.MaxReusableCandidates; i++ {
		c := arena.Next()
		c.costMs = float64(i + 1)
		c.provider = provider
		c.snapshot.model = "retained-evidence"
		slots = append(slots, c)
	}
	overflow := arena.Next()
	overflow.costMs, overflow.provider = 17, provider
	storage.Reset()
	for i, c := range slots {
		if c.costMs != 0 || c.provider != nil || c.snapshot.model != "" {
			t.Fatalf("reset retained references in slot %d", i)
		}
	}
	if overflow.costMs != 17 || overflow.provider != provider {
		t.Fatal("reset changed request-owned overflow storage")
	}
	second := candidatearena.Arena[arenaTestCandidate]{Storage: &storage}
	reused := second.Next()
	if reused != slots[0] || reused.costMs != 0 || reused.provider != nil {
		t.Fatal("exclusive reset storage not reused from first slot")
	}
	reused.provider, reused.snapshot.model = provider, "rejected"
	second.Release(reused)
	if second.Next() != reused || reused.provider != nil || reused.snapshot.model != "" {
		t.Fatal("released candidate was not cleared for reuse")
	}
	storage.Reset()
	for _, c := range slots {
		if c.provider != nil || c.snapshot.model != "" {
			t.Fatal("smaller scan retained a historical reference")
		}
	}
}

func TestCandidateStoragePassesDoNotAlias(t *testing.T) {
	var storage candidatearena.Storage[arenaTestCandidate]
	normal := candidatearena.Arena[arenaTestCandidate]{Storage: &storage}
	first := normal.Next()
	first.costMs, first.snapshot.model = 42, "normal"
	failOpen := candidatearena.Arena[arenaTestCandidate]{Storage: &storage}
	second := failOpen.Next()
	second.costMs, second.snapshot.model = 43, "fail-open"
	if second == first || first.costMs != 42 || first.snapshot.model != "normal" {
		t.Fatal("second pass overwrote a retained first-pass candidate")
	}
	storage.Reset()
	if first.snapshot.model != "" || second.snapshot.model != "" {
		t.Fatal("reset retained evidence from a scan pass")
	}
}
