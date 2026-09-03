package routingsim_test

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/routingsim"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func i64p(v int64) *int64 { return &v }

// profilesNDJSON renders records the way the admin export does (one JSON
// object per line) with a blank line in the middle to prove blanks are
// skipped.
func profilesNDJSON(t *testing.T, records ...store.RequestProfileRecord) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	for i, rec := range records {
		b, err := json.Marshal(rec)
		if err != nil {
			t.Fatalf("marshal record %d: %v", i, err)
		}
		buf.Write(b)
		buf.WriteByte('\n')
		if i == 0 {
			buf.WriteString("\n")
		}
	}
	return &buf
}

// profileFixtures returns five export rows in deliberately shuffled time
// order: three winning attempts with a prompt shape (a, b, c), one losing
// backup attempt and one winning row with no estimated prompt tokens.
func profileFixtures(t0 time.Time) []store.RequestProfileRecord {
	return []store.RequestProfileRecord{
		{
			CoordRequestID: "coord-c", RequestID: "req-c", Attempt: 0, Winning: true, Model: simModel,
			ProviderID: "prov-2", EstimatedPromptTokens: 1200, RequestedMaxTokens: 256, RequiresVision: true,
			ReceivedAt: t0.Add(2 * time.Second), WriteDoneUS: i64p(100_000), FirstContentIngressUS: i64p(500_000),
		},
		{
			CoordRequestID: "coord-a", RequestID: "req-a", Attempt: 0, Winning: true, Model: simModel,
			ProviderID: "prov-1", EstimatedPromptTokens: 300, RequestedMaxTokens: 512, HasTools: true,
			ReceivedAt: t0, WriteDoneUS: i64p(90_000), // first_content_us absent → TTFT unknown
		},
		{ // losing backup attempt of coord-b: never an arrival
			CoordRequestID: "coord-b", RequestID: "req-b-backup", Attempt: 1, BackupOf: "req-b", Winning: false,
			Model: simModel, ProviderID: "prov-3", EstimatedPromptTokens: 800, RequestedMaxTokens: 128,
			ReceivedAt: t0.Add(time.Second),
		},
		{ // no request shape recorded: skipped
			CoordRequestID: "coord-d", RequestID: "req-d", Attempt: 0, Winning: true, Model: simModel,
			ProviderID: "prov-1", EstimatedPromptTokens: 0, RequestedMaxTokens: 64, ReceivedAt: t0.Add(time.Second),
		},
		{
			CoordRequestID: "coord-b", RequestID: "req-b", Attempt: 0, Winning: true, Model: simModel,
			ProviderID: "prov-1", EstimatedPromptTokens: 800, RequestedMaxTokens: 128,
			ReceivedAt: t0.Add(time.Second), WriteDoneUS: i64p(400_000), FirstContentIngressUS: i64p(300_000), // clock anomaly → unknown
		},
	}
}

func TestLoadProfilesNDJSONRoundTrip(t *testing.T) {
	t0 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	arrivals, err := routingsim.LoadProfilesNDJSON(profilesNDJSON(t, profileFixtures(t0)...))
	if err != nil {
		t.Fatalf("LoadProfilesNDJSON: %v", err)
	}
	if len(arrivals) != 3 {
		t.Fatalf("got %d arrivals, want 3: %+v", len(arrivals), arrivals)
	}
	want := []routingsim.Arrival{
		{Model: simModel, PromptTokens: 300, MaxTokens: 512, ArrivedAt: t0, HasTools: true,
			ChosenProviderID: "prov-1", ActualTTFTMs: 0, CoordRequestID: "coord-a", Attempt: 0, Served: true},
		{Model: simModel, PromptTokens: 800, MaxTokens: 128, ArrivedAt: t0.Add(time.Second),
			ChosenProviderID: "prov-1", ActualTTFTMs: 0, CoordRequestID: "coord-b", Attempt: 0, Served: true},
		{Model: simModel, PromptTokens: 1200, MaxTokens: 256, ArrivedAt: t0.Add(2 * time.Second), RequiresVision: true,
			ChosenProviderID: "prov-2", ActualTTFTMs: 400, CoordRequestID: "coord-c", Attempt: 0, Served: true},
	}
	for i, w := range want {
		g := arrivals[i]
		if !g.ArrivedAt.Equal(w.ArrivedAt) {
			t.Errorf("arrival %d ArrivedAt = %s, want %s", i, g.ArrivedAt, w.ArrivedAt)
		}
		g.ArrivedAt, w.ArrivedAt = time.Time{}, time.Time{}
		if g != w {
			t.Errorf("arrival %d = %+v, want %+v", i, g, w)
		}
	}
}

func TestLoadProfilesNDJSONMalformedLineReportsLineNumber(t *testing.T) {
	t0 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	good := profilesNDJSON(t, profileFixtures(t0)[0])
	// Line 1 = good record, line 2 = blank (the helper's spacer), line 3 = garbage.
	good.WriteString(`{"coord_request_id": "x", "winning": tru` + "\n")
	arrivals, err := routingsim.LoadProfilesNDJSON(good)
	if err == nil {
		t.Fatal("expected an error for the malformed line")
	}
	if !strings.Contains(err.Error(), "line 3") {
		t.Fatalf("error %q does not name line 3", err)
	}
	if arrivals != nil {
		t.Fatalf("partial trace returned alongside the error: %+v", arrivals)
	}
}

func TestLoadProfilesNDJSONEmptyInput(t *testing.T) {
	arrivals, err := routingsim.LoadProfilesNDJSON(strings.NewReader("\n\n"))
	if err != nil || len(arrivals) != 0 {
		t.Fatalf("empty input = (%v, %v), want (empty, nil)", arrivals, err)
	}
	if _, err := routingsim.LoadProfilesNDJSON(nil); err == nil {
		t.Fatal("nil reader must error")
	}
}

// TestLoadProfilesNDJSONKeepsFailedRequests pins the demand-preserving
// selection: a logical request whose every attempt failed still becomes ONE
// arrival (Served=false, TTFT unknown), a primary+backup pair yields one
// arrival from the winner, and a loser-only pair picks the primary.
func TestLoadProfilesNDJSONKeepsFailedRequests(t *testing.T) {
	t0 := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	rows := []store.RequestProfileRecord{
		{ // fully failed: two attempts, neither won
			CoordRequestID: "coord-fail", RequestID: "req-f1", Attempt: 1, Model: simModel,
			ProviderID: "prov-2", EstimatedPromptTokens: 400, RequestedMaxTokens: 64, ReceivedAt: t0.Add(time.Second),
			FinalStatus: "error", WriteDoneUS: i64p(10_000), FirstContentIngressUS: i64p(20_000),
		},
		{
			CoordRequestID: "coord-fail", RequestID: "req-f0", Attempt: 0, Model: simModel,
			ProviderID: "prov-1", EstimatedPromptTokens: 400, RequestedMaxTokens: 64, ReceivedAt: t0.Add(time.Second),
			FinalStatus: "error",
		},
		{ // failed primary + failed backup: the primary represents the request
			CoordRequestID: "coord-lost", RequestID: "req-l-backup", Attempt: 0, BackupOf: "req-l", Model: simModel,
			ProviderID: "prov-3", EstimatedPromptTokens: 500, RequestedMaxTokens: 64, ReceivedAt: t0.Add(2 * time.Second),
		},
		{
			CoordRequestID: "coord-lost", RequestID: "req-l", Attempt: 0, Model: simModel,
			ProviderID: "prov-1", EstimatedPromptTokens: 500, RequestedMaxTokens: 64, ReceivedAt: t0.Add(2 * time.Second),
		},
		{ // winner with a losing backup: exactly one arrival, from the winner
			CoordRequestID: "coord-win", RequestID: "req-w-backup", Attempt: 0, BackupOf: "req-w", Model: simModel,
			ProviderID: "prov-3", EstimatedPromptTokens: 600, RequestedMaxTokens: 64, ReceivedAt: t0,
		},
		{
			CoordRequestID: "coord-win", RequestID: "req-w", Attempt: 0, Winning: true, Model: simModel,
			ProviderID: "prov-1", EstimatedPromptTokens: 600, RequestedMaxTokens: 64, ReceivedAt: t0,
			WriteDoneUS: i64p(10_000), FirstContentIngressUS: i64p(60_000),
		},
	}
	arrivals, err := routingsim.LoadProfilesNDJSON(profilesNDJSON(t, rows...))
	if err != nil {
		t.Fatal(err)
	}
	if len(arrivals) != 3 {
		t.Fatalf("arrivals = %d, want 3 (one per logical request): %+v", len(arrivals), arrivals)
	}
	byID := map[string]routingsim.Arrival{}
	for _, a := range arrivals {
		byID[a.CoordRequestID] = a
	}
	if a := byID["coord-win"]; !a.Served || a.ChosenProviderID != "prov-1" || a.ActualTTFTMs != 50 {
		t.Fatalf("winner arrival = %+v, want served by prov-1 with 50ms TTFT", a)
	}
	if a := byID["coord-fail"]; a.Served || a.Attempt != 0 || a.ChosenProviderID != "prov-1" || a.ActualTTFTMs != 0 {
		t.Fatalf("failed arrival = %+v, want attempt 0 representative, unserved, TTFT unknown", a)
	}
	if a := byID["coord-lost"]; a.Served || a.ChosenProviderID != "prov-1" {
		t.Fatalf("lost arrival = %+v, want the primary (not the backup) to represent it", a)
	}
	if arrivals[0].CoordRequestID != "coord-win" || arrivals[2].CoordRequestID != "coord-lost" {
		t.Fatalf("arrivals not in arrival-time order: %v", []string{arrivals[0].CoordRequestID, arrivals[1].CoordRequestID, arrivals[2].CoordRequestID})
	}
}
