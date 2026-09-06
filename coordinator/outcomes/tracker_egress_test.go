package outcomes

import (
	"sync"
	"testing"
	"time"
)

func TestRequestAccountingResponseTerminalAgreement(t *testing.T) {
	for _, first := range []string{"completed", "incomplete", "error"} {
		for _, next := range []string{"completed", "incomplete", "error"} {
			t.Run(first+"_then_"+next, func(t *testing.T) {
				tr := accountingFixture()
				a := sentAttempt(tr, "winner", 0, "")
				a.Observe("committed", "", 0)
				a.Observe("provider_complete", "", 0)
				tr.Egress(true, false, first)
				tr.Egress(true, false, next)
				tr.Egress(true, false, first)
				tr.Finish(200, false, false)
				row := tr.Snapshot()
				conflict := first != next
				if row.ResponseTerminal != first || row.EvidenceConflict != conflict {
					t.Fatalf("response terminals lost agreement evidence: %+v", row)
				}
				if conflict && (row.Termination != "unknown" || row.ResponseProgress == "completion_confirmed") {
					t.Fatalf("contradictory response terminal claimed completion: %+v", row)
				}
				if !conflict && (row.Termination == "completed") != (first == "completed") {
					t.Fatalf("duplicate terminal changed the outcome: %+v", row)
				}
			})
		}
	}
}

func TestRequestAccountingLateResponseTerminalConflictIsPersistedOnce(t *testing.T) {
	var published []*Record
	tr := New("late-egress", "/v1/responses", time.Now().Add(-time.Second), func(r *Record) { published = append(published, r) })
	a := sentAttempt(tr, "winner", 0, "")
	a.Observe("committed", "", 0)
	a.Observe("provider_complete", "", 0)
	tr.Egress(true, false, "completed")
	tr.Finish(200, false, false)
	before := tr.Snapshot()
	tr.Egress(true, false, "completed", "unknown", "")
	if tr.Snapshot().Revision != before.Revision {
		t.Fatal("duplicate or unknown terminal published a new revision")
	}
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); tr.Egress(true, false, "error") }()
	}
	wg.Wait()
	after := tr.Snapshot()
	if !after.EvidenceConflict || after.Termination != "unknown" || after.ResponseProgress == "completion_confirmed" || after.ResponseTerminal != "completed" {
		t.Fatalf("late contradictory terminal was lost: %+v", after)
	}
	if after.Revision != before.Revision+1 || len(published) != 3 || !published[2].EvidenceConflict {
		t.Fatalf("late conflict was not persisted exactly once: revision=%d snapshots=%d", after.Revision, len(published))
	}
	if !after.ReceivedAt.Equal(before.ReceivedAt) || !after.FinalizedAt.Equal(*before.FinalizedAt) || !after.ObservedAt.After(before.ObservedAt) {
		t.Fatal("late conflict moved the receipt or handler-exit cohort")
	}
}
