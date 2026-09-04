package payments

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestRecordUsageIsBounded: 1,000 completions leave the newest 100 entries,
// in order, on a backing array that stops growing. Before the cap the
// slice grew without bound (the fails-before run reported 1,000 entries).
func TestRecordUsageIsBounded(t *testing.T) {
	l := NewLedger(store.NewMemory(store.Config{}))
	const consumer = "bounded-consumer"
	for i := 0; i < 1000; i++ {
		l.RecordUsage(consumer, UsageEntry{JobID: fmt.Sprintf("job-%d", i), CostMicroUSD: int64(i), Timestamp: time.Now()})
	}
	got := l.Usage(consumer)
	if len(got) != usageHistoryCap {
		t.Fatalf("usage entries = %d, want %d", len(got), usageHistoryCap)
	}
	for i, e := range got {
		if want := fmt.Sprintf("job-%d", 1000-usageHistoryCap+i); e.JobID != want {
			t.Fatalf("entry %d = %s, want %s (newest %d, chronological)", i, e.JobID, want, usageHistoryCap)
		}
	}
	// The backing array stops growing once the cap is reached: 10,000 more
	// completions leave its capacity exactly where it was.
	l.mu.RLock()
	backing := cap(l.usage[consumer])
	l.mu.RUnlock()
	if backing > 2*usageHistoryCap {
		t.Fatalf("backing array cap = %d, want <= %d", backing, 2*usageHistoryCap)
	}
	for i := 1000; i < 11000; i++ {
		l.RecordUsage(consumer, UsageEntry{JobID: fmt.Sprintf("job-%d", i)})
	}
	l.mu.RLock()
	after := cap(l.usage[consumer])
	l.mu.RUnlock()
	if after != backing {
		t.Fatalf("backing array grew from %d to %d after the cap was reached", backing, after)
	}
	if got := l.Usage(consumer); len(got) != usageHistoryCap || got[usageHistoryCap-1].JobID != "job-10999" {
		t.Fatalf("after 11,000 completions: %d entries, last %s", len(got), got[len(got)-1].JobID)
	}
	// Other consumers are unaffected and an empty history stays empty.
	if n := len(l.Usage("someone-else")); n != 0 {
		t.Fatalf("unrelated consumer has %d entries", n)
	}
}

func BenchmarkRecordUsageSteadyState(b *testing.B) {
	l := NewLedger(store.NewMemory(store.Config{}))
	entry := UsageEntry{JobID: "job", Model: "m", PromptTokens: 10, CompletionTokens: 20, CostMicroUSD: 5}
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		l.RecordUsage("bench", entry)
	}
}
