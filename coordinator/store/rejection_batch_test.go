package store

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

// The column list, the per-row parameter count and the argument builder must
// agree, or the multi-row VALUES tuples would be misaligned with the columns.
func TestRejectionInsertSQLShape(t *testing.T) {
	if n := len(strings.Split(rejectionInsertColumns, ",")); n != rejectionInsertParamCount {
		t.Fatalf("column list has %d entries, rejectionInsertParamCount = %d", n, rejectionInsertParamCount)
	}
	one := rejectionInsertSQL(1)
	if !strings.HasSuffix(strings.TrimSpace(one), "$36)") || strings.Contains(one, "$37") {
		t.Fatalf("single-row statement must end its tuple at $36: %s", one)
	}
	three := rejectionInsertSQL(3)
	if strings.Count(three, "VALUES (") != 1 || strings.Count(three, "($") != 3 {
		t.Fatalf("three-row statement must have exactly three tuples: %s", three)
	}
	if !strings.Contains(three, "$108)") || strings.Contains(three, "$109") {
		t.Fatalf("three-row statement must end at $108: %s", three)
	}
	if got := len(rejectionInsertArgs(nil, &RejectionRecord{}, time.Now())); got != rejectionInsertParamCount {
		t.Fatalf("rejectionInsertArgs produced %d args, want %d", got, rejectionInsertParamCount)
	}
	// Empty params bind as a nil RawMessage (pgx encodes it as SQL NULL),
	// never an invalid empty JSONB value.
	args := rejectionInsertArgs(nil, &RejectionRecord{}, time.Now())
	if p, ok := args[22].(json.RawMessage); !ok || p != nil {
		t.Fatalf("empty Params bound as %#v, want a nil json.RawMessage", args[22])
	}
	args = rejectionInsertArgs(nil, &RejectionRecord{Params: json.RawMessage(`{"t":1}`)}, time.Now())
	if p, ok := args[22].(json.RawMessage); !ok || string(p) != `{"t":1}` {
		t.Fatalf("Params bound as %#v", args[22])
	}
	chunks := splitRejectionBatches([]*RejectionRecord{{Stage: "a"}, nil, {Stage: "b"}, {Stage: "c"}}, 2)
	if len(chunks) != 2 || len(chunks[0]) != 2 || len(chunks[1]) != 1 || chunks[1][0].Stage != "c" {
		t.Fatalf("splitRejectionBatches = %+v", chunks)
	}
	if got := splitRejectionBatches([]*RejectionRecord{nil}, 0); len(got) != 0 {
		t.Fatalf("nil-only input yields %d batches, want 0", len(got))
	}
}

// RecordRejections has the per-row semantics of RecordRejection on both
// backends: every non-nil row lands, a zero CreatedAt defaults to now, an
// explicit one is kept, params round-trip, and empty params read back empty.
func TestRejectionBatch(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) { testRejectionBatch(t, s) })
	}
}

func testRejectionBatch(t *testing.T, s Store) {
	t.Helper()
	if err := s.RecordRejections(nil); err != nil {
		t.Fatalf("RecordRejections(nil): %v", err)
	}
	if err := s.RecordRejections([]*RejectionRecord{nil}); err != nil {
		t.Fatalf("RecordRejections([nil]): %v", err)
	}
	prefix := uniqueID("rej")
	id := func(i int) string { return fmt.Sprintf("%s-%d", prefix, i) }
	explicit := time.Now().Add(-time.Hour).UTC().Truncate(time.Microsecond)
	before := time.Now().Add(-time.Second)

	rows := []*RejectionRecord{
		{RequestID: id(1), Endpoint: "/v1/chat/completions", Stage: "ratelimit", ReasonCode: "requests", HTTPStatus: 429, LimitKind: "key", RetryAfterMs: 4000, CreatedAt: explicit},
		nil,
		{RequestID: id(2), Stage: "ratelimit", ReasonCode: "output_tokens", HTTPStatus: 429, RequestedModel: "m", EstimatedPromptTokens: 12, RequestedMaxTokens: 8192, Params: json.RawMessage(`{"temperature":0.2}`), CandidateCount: 3, CouldHaveServed: true},
		{RequestID: id(3), Stage: "drain", ReasonCode: "draining", HTTPStatus: 429, HasTools: true, ToolCount: 2},
	}
	if err := s.RecordRejections(rows); err != nil {
		t.Fatalf("RecordRejections: %v", err)
	}
	got := map[string]RejectionRecord{}
	for _, r := range s.RejectionRecordsSince(time.Time{}) {
		if strings.HasPrefix(r.RequestID, prefix) {
			got[r.RequestID] = r
		}
	}
	if len(got) != 3 {
		t.Fatalf("persisted %d rows for the batch, want 3: %+v", len(got), got)
	}
	r1 := got[id(1)]
	if r1.Stage != "ratelimit" || r1.ReasonCode != "requests" || r1.HTTPStatus != 429 || r1.LimitKind != "key" || r1.RetryAfterMs != 4000 {
		t.Fatalf("row 1 = %+v", r1)
	}
	if !r1.CreatedAt.UTC().Equal(explicit) {
		t.Fatalf("row 1 created_at = %v, want the explicit %v", r1.CreatedAt, explicit)
	}
	if len(r1.Params) != 0 {
		t.Fatalf("row 1 params = %s, want empty (bound as NULL)", r1.Params)
	}
	r2 := got[id(2)]
	if r2.RequestedModel != "m" || r2.EstimatedPromptTokens != 12 || r2.RequestedMaxTokens != 8192 || r2.CandidateCount != 3 || !r2.CouldHaveServed {
		t.Fatalf("row 2 = %+v", r2)
	}
	var params map[string]any
	if err := json.Unmarshal(r2.Params, &params); err != nil || params["temperature"] != 0.2 {
		t.Fatalf("row 2 params = %s (%v)", r2.Params, err)
	}
	if r2.CreatedAt.Before(before) {
		t.Fatalf("row 2 created_at = %v, want defaulted to now", r2.CreatedAt)
	}
	r3 := got[id(3)]
	if r3.Stage != "drain" || !r3.HasTools || r3.ToolCount != 2 {
		t.Fatalf("row 3 = %+v", r3)
	}
	// The single-row path keeps working through the shared builder.
	if err := s.RecordRejection(&RejectionRecord{RequestID: id(4), Stage: "auth", HTTPStatus: 401}); err != nil {
		t.Fatalf("RecordRejection: %v", err)
	}
	found := false
	for _, r := range s.RejectionRecordsSince(time.Time{}) {
		if r.RequestID == id(4) && r.Stage == "auth" {
			found = true
		}
	}
	if !found {
		t.Fatal("single-row RecordRejection did not persist")
	}
}
