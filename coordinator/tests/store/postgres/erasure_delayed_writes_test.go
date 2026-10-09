package postgres_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func erasureDelayedScrub(t *testing.T, s store.Store, a erasurefixture.Account) {
	t.Helper()
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	if _, err := s.ScrubAccount(context.Background(), req.ID, now); err != nil {
		t.Fatal(err)
	}
}

func erasureDelayedEvidence(a erasurefixture.Account, id string) store.AppAttestEvidence {
	return store.AppAttestEvidence{ID: id, SessionID: a.ProviderID, KeyID: "late-key", ReceivedAt: time.Now().UTC(), Action: "attestation", SHA256: "abc", Context: json.RawMessage(`{"boot_time":"personal-marker"}`), ProofField: "personal-proof", Proof: []byte("personal-proof")}
}

func TestErasureDelayedReceiptRenewalAfterScrub(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	if err := s.BeginAppAttestEvidence(ctx, erasureDelayedEvidence(a, "old-evidence")); err != nil {
		t.Fatal(err)
	}
	old := store.AppAttestReceipt{ID: "old-receipt", KeyID: "late-key", EvidenceID: "old-evidence", ReceivedAt: now, Outcome: "verified", Body: []byte("personal-receipt"), Context: json.RawMessage(`{"boot_time":"personal-marker"}`), Details: json.RawMessage(`{}`), NextAt: now.Add(-time.Second), ExpiresAt: now.Add(time.Hour)}
	if err := s.SaveAppAttestReceiptRefresh(ctx, old); err != nil {
		t.Fatal(err)
	}
	claimed, err := s.ClaimAppAttestReceipt(ctx, now)
	if err != nil || claimed == nil {
		t.Fatalf("claim=%+v %v", claimed, err)
	}
	erasureDelayedScrub(t, s, a)
	next := *claimed
	next.ID = "late-receipt"
	next.ParentID = old.ID
	next.NextAt = now.Add(time.Hour)
	next.ResponseBody = []byte("personal-response")
	err = s.SaveAppAttestReceiptRefresh(ctx, next)
	var blobs, jobs, contexts int
	if e := s.pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM app_attest_receipt_blobs WHERE receipt_id='late-receipt'), (SELECT count(*) FROM app_attest_receipt_jobs WHERE key_id='late-key'), (SELECT count(*) FROM app_attest_receipts WHERE id='late-receipt' AND context::text LIKE '%personal-marker%')`).Scan(&blobs, &jobs, &contexts); e != nil {
		t.Fatal(e)
	}
	if blobs+jobs+contexts != 0 {
		t.Fatalf("receipt renewal restored blobs=%d jobs=%d personal contexts=%d after scrub (save error=%v)", blobs, jobs, contexts, err)
	}
}

func TestErasureDelayedEvidenceCompletionAfterScrub(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	if err := s.BeginAppAttestEvidence(ctx, erasureDelayedEvidence(a, "pending-evidence")); err != nil {
		t.Fatal(err)
	}
	erasureDelayedScrub(t, s, a)
	receipt := &store.AppAttestReceipt{ID: "completion-receipt", KeyID: "late-key", EvidenceID: "pending-evidence", ReceivedAt: time.Now().UTC(), Outcome: "attestation_not_verified", Body: []byte("personal-body"), Context: json.RawMessage(`{"boot_time":"personal-marker"}`), Details: json.RawMessage(`{}`)}
	_, err := s.CompleteAppAttestEvidence(ctx, "pending-evidence", store.AppAttestDecision{Outcome: "rejected", Receipt: receipt})
	var n int
	if e := s.pool.QueryRow(ctx, `SELECT count(*) FROM app_attest_receipt_blobs WHERE receipt_id='completion-receipt'`).Scan(&n); e != nil {
		t.Fatal(e)
	}
	if n != 0 {
		t.Fatalf("proof completion restored personal receipt blob after scrub (completion error=%v)", err)
	}
}

func TestErasureDelayedEvidenceAdmissionAfterScrub(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	erasureDelayedScrub(t, s, a)
	err := s.BeginAppAttestEvidence(ctx, erasureDelayedEvidence(a, "late-evidence"))
	var n int
	if e := s.pool.QueryRow(ctx, `SELECT count(*) FROM app_attest_evidence_blobs WHERE evidence_id='late-evidence'`).Scan(&n); e != nil {
		t.Fatal(e)
	}
	if n != 0 {
		t.Fatalf("proof admission restored personal proof blob after scrub (begin error=%v)", err)
	}
}

func TestErasureDelayedUnlinkedSessionBackfillAfterScrub(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	if err := s.OpenProviderSession(ctx, a.ProviderID, "", ""); err != nil {
		t.Fatal(err)
	}
	erasureDelayedScrub(t, s, a)
	err := s.TouchProviderSession(ctx, a.ProviderID, "personal-serial", a.AccountID, "provider-key", time.Now())
	var serial string
	if e := s.pool.QueryRow(ctx, `SELECT serial_number FROM provider_sessions WHERE session_id=$1`, a.ProviderID).Scan(&serial); e != nil {
		t.Fatal(e)
	}
	if serial != "" {
		t.Fatalf("session backfill restored serial=%s after scrub (touch error=%v)", serial, err)
	}
}

func TestErasureDelayedLogUploadAfterScrub(t *testing.T) {
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	erasureDelayedScrub(t, s, a)
	id, err := s.StoreLogReport(a.AccountID, []byte("personal raw log"))
	if err == nil {
		if r, e := s.GetLogReport(id); e == nil && len(r.LogData) > 0 {
			t.Fatalf("late upload retained personal log after scrub: %s", r.LogData)
		}
	}
}

func TestErasureDelayedCheckoutCopiesErasedReferrerCode(t *testing.T) {
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	b := erasurefixture.SeedAccount(t, s)
	if err := s.CreateReferrer(a.AccountID, "PERSONAL-CODE"); err != nil {
		t.Fatal(err)
	}
	// The handler already resolved this code and is awaiting Stripe for live account B.
	if _, err := s.GetReferrerByCode("PERSONAL-CODE"); err != nil {
		t.Fatal(err)
	}
	erasureDelayedScrub(t, s, a)
	err := s.CreateBillingSession(&store.BillingSession{ID: "late-checkout", AccountID: b.AccountID, PaymentMethod: "stripe", ExternalID: "cs_late", Status: "pending", ReferralCode: "PERSONAL-CODE"})
	bs, e := s.GetBillingSession("late-checkout")
	if e == nil && bs.ReferralCode == "PERSONAL-CODE" {
		t.Fatalf("live customer's delayed checkout restores erased referrer's personal code (create error=%v)", err)
	}
}

func TestErasureDelayedCodeAttestationAfterScrub(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	proof := store.CodeAttestation{SEPubKey: a.SEKey, Version: "0.1", AttestedAt: time.Now(), APNsToken: "personal-apns-token", NodePublicKey: "node-key", BinaryHash: "binary"}
	erasureDelayedScrub(t, s, a)
	err := s.UpsertCodeAttestation(ctx, proof)
	var n int
	if e := s.pool.QueryRow(ctx, `SELECT count(*) FROM code_attestations WHERE se_pubkey=$1 AND apns_token='personal-apns-token'`, a.SEKey).Scan(&n); e != nil {
		t.Fatal(e)
	}
	if n != 0 {
		t.Fatalf("async code-attestation persistence restored APNs token after scrub (save error=%v)", err)
	}
}

// A writer admitted before scrub may wait on I/O. Its newly persisted ownership
// and evidence must be collected after the shared writer fence is drained.
func TestErasureIncludesAdmittedEvidenceBeforeKeyCollection(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	blocker, err := s.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Rollback(ctx)
	if _, err = blocker.Exec(ctx, `LOCK TABLE app_attest_evidence IN ACCESS EXCLUSIVE MODE`); err != nil {
		t.Fatal(err)
	}
	evidence := erasureDelayedEvidence(a, "waiting-evidence")
	evidence.AccountID = a.AccountID
	evidence.SessionID = "new-session-before-scrub"
	writer := make(chan error, 1)
	go func() { writer <- s.BeginAppAttestEvidence(ctx, evidence) }()
	waitErasureLock(t, s, "INSERT INTO app_attest_evidence", 1)
	scrub := make(chan error, 1)
	go func() { _, err := s.ScrubAccount(ctx, req.ID, now); scrub <- err }()
	waitErasureLock(t, s, "pg_advisory_xact_lock(714320, 2)", 1)
	if err = blocker.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err = <-writer; err != nil {
		t.Fatal(err)
	}
	if err = <-scrub; err != nil {
		t.Fatal(err)
	}
	var blobs int
	if err = s.pool.QueryRow(ctx, `SELECT count(*) FROM app_attest_evidence_blobs WHERE evidence_id=$1`, evidence.ID).Scan(&blobs); err != nil {
		t.Fatal(err)
	}
	if blobs != 0 {
		t.Fatal("scrub missed evidence committed before key collection")
	}
}

func TestErasureSharedReceiptRenewalUntilLastOwner(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a, b := erasurefixture.SeedAccount(t, s), erasurefixture.SeedAccount(t, s)
	now := time.Now().UTC()
	for _, owner := range []erasurefixture.Account{a, b} {
		e := erasureDelayedEvidence(owner, owner.ProviderID)
		e.AccountID = owner.AccountID
		if err := s.BeginAppAttestEvidence(ctx, e); err != nil {
			t.Fatal(err)
		}
	}
	original := store.AppAttestReceipt{ID: "shared-receipt", KeyID: "late-key", EvidenceID: a.ProviderID, ReceivedAt: now, Outcome: "verified", Body: []byte("shared-device-receipt"), Context: json.RawMessage(`{}`), Details: json.RawMessage(`{}`), NextAt: now.Add(-time.Second), ExpiresAt: now.Add(time.Hour)}
	if err := s.SaveAppAttestReceiptRefresh(ctx, original); err != nil {
		t.Fatal(err)
	}
	claimed, err := s.ClaimAppAttestReceipt(ctx, now)
	if err != nil || claimed == nil {
		t.Fatalf("claim = %v %v", claimed, err)
	}
	erasureDelayedScrub(t, s, a)
	renewed := *claimed
	renewed.ID = "shared-renewed"
	renewed.ParentID = claimed.ID
	renewed.NextAt = now.Add(time.Hour)
	if err = s.SaveAppAttestReceiptRefresh(ctx, renewed); err != nil {
		t.Fatal(err)
	}
	var blobs int
	if err = s.pool.QueryRow(ctx, `SELECT count(*) FROM app_attest_receipt_blobs WHERE receipt_id=$1`, renewed.ID).Scan(&blobs); err != nil || blobs != 1 {
		t.Fatalf("shared renewal blobs=%d %v", blobs, err)
	}
	erasureDelayedScrub(t, s, b)
	renewed.ParentID = renewed.ID
	renewed.ID = "last-owner-delayed"
	if err = s.SaveAppAttestReceiptRefresh(ctx, renewed); err == nil {
		t.Fatal("receipt renewed after last owner's scrub")
	}
}
