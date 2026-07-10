package ownership

import (
	"context"
	"encoding/json"
	"testing"
)

type memTerminalStore struct {
	byKey    map[string]*TerminalDisposition
	byDigest map[string]*TerminalDisposition
	late     []TerminalIngest
}

func (m *memTerminalStore) LookupRustTerminal(ctx context.Context, attemptID, digest string) (*TerminalDisposition, error) {
	return m.byKey[attemptID+"|"+digest], nil
}

func (m *memTerminalStore) LookupRustTerminalByDigest(ctx context.Context, digest string) (*TerminalDisposition, error) {
	if m.byDigest == nil {
		return nil, nil
	}
	return m.byDigest[digest], nil
}

func (m *memTerminalStore) RecordLateTerminal(ctx context.Context, t TerminalIngest) error {
	m.late = append(m.late, t)
	return nil
}

func TestIngestTerminal_ReturnsPriorDisposition(t *testing.T) {
	ack, _ := json.Marshal(map[string]string{"type": "terminal_ack", "disposition": "settled"})
	st := &memTerminalStore{byKey: map[string]*TerminalDisposition{
		"a1|d1": {Disposition: "settled", JobID: "j", AckPayload: ack},
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

func TestIngestTerminal_WrongJobIDReturnsConflict(t *testing.T) {
	st := &memTerminalStore{byKey: map[string]*TerminalDisposition{
		"a1|d1": {Disposition: "settled", JobID: "j-real"},
	}}
	out, err := IngestTerminal(context.Background(), st, TerminalIngest{
		JobID: "j-attacker", AttemptID: "a1", TerminalDigest: "d1",
	})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.Unmarshal(out, &got)
	if got["disposition"] != "conflict" {
		t.Fatalf("expected conflict, got %v", got)
	}
	if len(st.late) != 0 {
		t.Fatal("must not record late on job mismatch")
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

func TestIngestTerminal_DigestOnlyFallback(t *testing.T) {
	st := &memTerminalStore{
		byKey: map[string]*TerminalDisposition{},
		byDigest: map[string]*TerminalDisposition{
			"d-empty": {Disposition: "settled", JobID: "j"},
		},
	}
	out, err := IngestTerminal(context.Background(), st, TerminalIngest{
		JobID: "j", AttemptID: "real-attempt", TerminalDigest: "d-empty",
	})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.Unmarshal(out, &got)
	if got["disposition"] != "settled" {
		t.Fatalf("expected settled via digest fallback, got %v", got)
	}
	if len(st.late) != 0 {
		t.Fatal("must not record late when digest fallback hits")
	}
}

func TestIngestTerminal_DigestFallbackWrongJobConflict(t *testing.T) {
	st := &memTerminalStore{
		byKey: map[string]*TerminalDisposition{},
		byDigest: map[string]*TerminalDisposition{
			"d-fb": {Disposition: "settled", JobID: "j-real"},
		},
	}
	out, err := IngestTerminal(context.Background(), st, TerminalIngest{
		JobID: "j-other", AttemptID: "a1", TerminalDigest: "d-fb",
	})
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	_ = json.Unmarshal(out, &got)
	if got["disposition"] != "conflict" {
		t.Fatalf("expected conflict, got %v", got)
	}
}
