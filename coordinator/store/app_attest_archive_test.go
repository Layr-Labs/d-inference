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
