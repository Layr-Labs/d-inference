package ownership

import (
	"context"
	"encoding/json"
	"testing"
)

type memTerminalStore struct {
	byKey map[string]*TerminalDisposition
	late  []TerminalIngest
}

func (m *memTerminalStore) LookupRustTerminal(ctx context.Context, attemptID, digest string) (*TerminalDisposition, error) {
	return m.byKey[attemptID+"|"+digest], nil
}

func (m *memTerminalStore) RecordLateTerminal(ctx context.Context, t TerminalIngest) error {
	m.late = append(m.late, t)
	return nil
}

func TestIngestTerminal_ReturnsPriorDisposition(t *testing.T) {
	ack, _ := json.Marshal(map[string]string{"type": "terminal_ack", "disposition": "settled"})
	st := &memTerminalStore{byKey: map[string]*TerminalDisposition{
		"a1|d1": {Disposition: "settled", AckPayload: ack},
	}}
	out, err := IngestTerminal(context.Background(), st, TerminalIngest{
		JobID: "j", AttemptID: "a1", TerminalDigest: "d1",
	})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]string
	_ = json.Unmarshal(out, &got)
	if got["disposition"] != "settled" {
		t.Fatalf("%s", out)
	}
	if len(st.late) != 0 {
		t.Fatal("must not record late when disposition exists")
	}
}

func TestIngestTerminal_UnknownIsLate(t *testing.T) {
	st := &memTerminalStore{byKey: map[string]*TerminalDisposition{}}
	out, err := IngestTerminal(context.Background(), st, TerminalIngest{
		JobID: "j", AttemptID: "a1", TerminalDigest: "d1",
	})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.Unmarshal(out, &got)
	if got["disposition"] != "late" {
		t.Fatalf("%v", got)
	}
	if len(st.late) != 1 {
		t.Fatal("expected late record")
	}
}
