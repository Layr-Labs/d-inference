package store

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/ownership"
)

func TestRustTerminalStore_IngestRoundTrip(t *testing.T) {
	st := NewRustTerminalStore()
	ack, _ := json.Marshal(map[string]string{"type": "terminal_ack", "disposition": "settled"})
	st.Put("a1", "d1", "settled", ack)
	out, err := ownership.IngestTerminal(context.Background(), st, ownership.TerminalIngest{
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
	_, err = ownership.IngestTerminal(context.Background(), st, ownership.TerminalIngest{
		JobID: "j", AttemptID: "a2", TerminalDigest: "d2",
	})
	if err != nil {
		t.Fatal(err)
	}
	if st.LateCount() != 1 {
		t.Fatalf("late=%d", st.LateCount())
	}
}
