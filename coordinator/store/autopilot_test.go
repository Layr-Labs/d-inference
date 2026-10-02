package store

import (
	"context"
	"testing"
	"time"
)

func TestAutopilotLedgerIdempotentAndOwnsArrays(t *testing.T) {
	s := NewMemory(Config{})
	now := time.Now()
	r := AutopilotRecord{CommandID: "one", ProviderID: "session", Phase: "reserved", At: now, Before: []string{"old"}, Unload: []string{"old"}, Load: "new"}
	if err := s.RecordAutopilot(context.Background(), []AutopilotRecord{r, r}); err != nil {
		t.Fatal(err)
	}
	r.Before[0] = "mutated"
	records, err := s.AutopilotRecords(context.Background(), now.Add(-time.Second), 10)
	if err != nil || len(records) != 1 || records[0].Before[0] != "old" {
		t.Fatalf("records=%+v err=%v", records, err)
	}
	records[0].Before[0] = "mutated-again"
	records, _ = s.AutopilotRecords(context.Background(), now.Add(-time.Second), 10)
	if records[0].Before[0] != "old" {
		t.Fatal("reader mutated ledger")
	}
}

func TestAutopilotLedgerConflictsPreserveFirstProposalAcrossBackends(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ledger, ok := As[AutopilotStore](backend)
			if !ok {
				t.Fatal("backend lacks Autopilot ledger")
			}
			now := time.Now()
			first := AutopilotRecord{CommandID: uniqueID("proposal"), ProviderID: "session", Phase: "proposed", At: now, Load: "target", Benefit: 12}
			later := first
			later.At, later.Benefit = now.Add(time.Minute), 99
			if err := ledger.RecordAutopilot(context.Background(), []AutopilotRecord{first, later}); err != nil {
				t.Fatal(err)
			}
			if err := ledger.RecordAutopilot(context.Background(), []AutopilotRecord{later}); err != nil {
				t.Fatal(err)
			}
			nextPhase, distinct := later, later
			nextPhase.Phase = "reserved"
			distinct.CommandID = uniqueID("distinct-proposal")
			if err := ledger.RecordAutopilot(context.Background(), []AutopilotRecord{nextPhase, distinct}); err != nil {
				t.Fatal(err)
			}
			records, err := ledger.AutopilotRecords(context.Background(), now, 1000)
			if err != nil {
				t.Fatal(err)
			}
			matched := 0
			for _, record := range records {
				if record.CommandID != first.CommandID && record.CommandID != distinct.CommandID {
					continue
				}
				matched++
				if record.CommandID == first.CommandID && record.Phase == "proposed" &&
					(!record.At.Equal(first.At) || record.Benefit != first.Benefit) {
					t.Fatalf("conflicting proposal replaced first observation: %+v", record)
				}
			}
			if matched != 3 {
				t.Fatalf("ledger must deduplicate proposals without collapsing phases or identities: %+v", records)
			}
		})
	}
}
