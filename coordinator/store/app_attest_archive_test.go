package store

import (
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func archiveContract(t *testing.T, s interface {
	AppAttestArchiveStore
	AppAttestShadowStore
}) {
	ctx := context.Background()
	begin := func() string {
		t.Helper()
		id := uuid.NewString()
		if err := s.BeginAppAttestEvidence(ctx, AppAttestEvidence{ID: id, SessionID: "session", KeyID: "key", ReceivedAt: time.Now(), Action: "assertion", ProofField: "bad!base64", Proof: []byte{0, 255}, SHA256: "checksum", Context: json.RawMessage(`{"challenge":"expected"}`)}); err != nil {
			t.Fatal(err)
		}
		return id
	}
	id := begin()
	if got, err := s.CompleteAppAttestEvidence(ctx, id, AppAttestDecision{Outcome: "malformed_proof"}); err != nil || got != "malformed_proof" {
		t.Fatalf("%s %v", got, err)
	}
	// A second completion can neither relabel a rejection nor enroll a key.
	key := AppAttestShadowKey{KeyID: "key", Owner: "owner", PublicKey: []byte{1}, AppID: "TEST.app", Environment: "production"}
	if got, err := s.CompleteAppAttestEvidence(ctx, id, AppAttestDecision{Outcome: "verified", Key: &key}); err != nil || got != "malformed_proof" {
		t.Fatalf("relabelled %s %v", got, err)
	}
	if got, _ := s.GetAppAttestShadowKey(ctx, key.KeyID); got != nil {
		t.Fatal("rejected evidence enrolled")
	}
	if got, err := s.CompleteAppAttestEvidence(ctx, begin(), AppAttestDecision{Outcome: "verified", Key: &key}); err != nil || got != "verified" {
		t.Fatalf("enroll %s %v", got, err)
	}
	var ids []string
	for i := 0; i < 12; i++ {
		ids = append(ids, begin())
	}
	var wg sync.WaitGroup
	var wins atomic.Int32
	for _, id := range ids {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			counter := uint32(1)
			got, err := s.CompleteAppAttestEvidence(ctx, id, AppAttestDecision{Outcome: "verified", KeyID: key.KeyID, Owner: key.Owner, Counter: &counter})
			if err != nil {
				t.Error(err)
			}
			if got == "verified" {
				wins.Add(1)
			}
		}(id)
	}
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("replay wins %d", wins.Load())
	}
	if got, err := s.CompleteAppAttestEvidence(ctx, begin(), AppAttestDecision{Outcome: "verified", Key: &key}); err != nil || got != "verified" {
		t.Fatalf("idempotent enroll %s %v", got, err)
	}
	stored, _ := s.GetAppAttestShadowKey(ctx, key.KeyID)
	if stored.Counter != 1 {
		t.Fatal("re-enrollment reset counter")
	}
}

func TestAppAttestArchiveMemory(t *testing.T) { archiveContract(t, NewMemory(Config{})) }
func TestAppAttestArchivePostgres(t *testing.T) {
	s := testPostgresStore(t)
	archiveContract(t, s)
	fresh := &PostgresStore{pool: s.pool}
	var field string
	var raw []byte
	if err := fresh.pool.QueryRow(context.Background(), `SELECT proof_field,proof FROM app_attest_evidence_blobs LIMIT 1`).Scan(&field, &raw); err != nil || field != "bad!base64" || string(raw) != string([]byte{0, 255}) {
		t.Fatalf("archive changed: %v", err)
	}
	id := uuid.NewString()
	ctx := context.Background()
	if err := s.BeginAppAttestEvidence(ctx, AppAttestEvidence{ID: id, ReceivedAt: time.Now(), Context: json.RawMessage(`{}`)}); err != nil {
		t.Fatal(err)
	}
	counter := uint32(2)
	if _, err := s.CompleteAppAttestEvidence(ctx, id, AppAttestDecision{Outcome: "verified", KeyID: "key", Owner: "owner", Counter: &counter, Details: json.RawMessage(`not json`)}); err == nil {
		t.Fatal("expected failed transaction")
	}
	stored, _ := fresh.GetAppAttestShadowKey(ctx, "key")
	if stored.Counter != 1 {
		t.Fatal("counter committed without result")
	}
}

func assertionDiagnosticContract(t *testing.T, s interface {
	AppAttestArchiveStore
	AppAttestDiagnosticStore
}) {
	t.Helper()
	ctx := t.Context()
	key := uuid.NewString()
	at := time.Unix(1_780_000_000, 0)
	appendEvidence := func(keyID, action, outcome, diagnostic string) {
		t.Helper()
		at = at.Add(time.Second)
		id := uuid.NewString()
		if err := s.BeginAppAttestEvidence(ctx, AppAttestEvidence{ID: id, SessionID: "session", KeyID: keyID,
			ReceivedAt: at, Action: action, Context: json.RawMessage(diagnostic), Proof: []byte("private proof")}); err != nil {
			t.Fatal(err)
		}
		if outcome != "pending" {
			if got, err := s.CompleteAppAttestEvidence(ctx, id, AppAttestDecision{Outcome: outcome}); err != nil || got != outcome {
				t.Fatalf("complete evidence: %s %v", got, err)
			}
		}
	}
	check := func(wantBoot, wantProcess string, wantRow bool) {
		t.Helper()
		got, err := s.GetAppAttestAssertionDiagnostics(ctx, key)
		if err != nil {
			t.Fatal(err)
		}
		if (got != nil) != wantRow {
			t.Fatalf("diagnostic baseline = %+v, want row=%v", got, wantRow)
		}
		if got == nil {
			return
		}
		// SQL NULL and absent JSON members both mean unknown.
		member := func(raw json.RawMessage) string {
			if string(raw) == "null" {
				return ""
			}
			return string(raw)
		}
		if member(got.BootTime) != wantBoot || member(got.ProcessStartedAt) != wantProcess {
			t.Fatalf("diagnostic baseline = %+v, want boot=%s process=%s", got, wantBoot, wantProcess)
		}
	}
	check("", "", false)
	appendEvidence(key, "attestation", "verified", `{"boot_time":1780000000,"process_started_at":1780000100}`)
	check("", "", false)
	appendEvidence(key, "assertion", "verified", `{"boot_time":1780000000,"process_started_at":1780000100,"challenge":"private"}`)
	appendEvidence(key, "assertion", "pending", `{"boot_time":1780000900}`)
	appendEvidence(key, "assertion", "apple_error", `{"boot_time":1780000900}`)
	appendEvidence("other-"+key, "assertion", "verified", `{"boot_time":1780000900}`)
	check("1780000000", "1780000100", true)
	// Do not skip a newer success from a legacy provider to reuse old context.
	appendEvidence(key, "assertion", "verified", `{}`)
	check("", "", true)
	appendEvidence(key, "assertion", "verified", `{"boot_time":1780001000,"process_started_at":"invalid"}`)
	check("1780001000", `"invalid"`, true)
	// The baseline is still usable as the oldest row inside the window.
	for range AppAttestDiagnosticLookback - 1 {
		appendEvidence(key, "assertion", "apple_error", `{}`)
	}
	check("1780001000", `"invalid"`, true)
	appendEvidence(key, "assertion", "pending", `{}`)
	check("", "", false)
	appendEvidence(key, "assertion", "verified", `{"boot_time":1780002000,"process_started_at":1780002100}`)
	check("1780002000", "1780002100", true)
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if got, err := s.GetAppAttestAssertionDiagnostics(cancelled, key); err == nil || got != nil {
		t.Fatal("cancelled diagnostic read returned evidence")
	}
}

func TestAppAttestAssertionDiagnosticsMemory(t *testing.T) {
	assertionDiagnosticContract(t, NewMemory(Config{}))
}

func TestAppAttestAssertionDiagnosticsPostgres(t *testing.T) {
	assertionDiagnosticContract(t, testPostgresStore(t))
}
