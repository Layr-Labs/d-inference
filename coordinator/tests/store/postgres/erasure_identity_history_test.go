package postgres_test

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
	"testing"
	"time"
)

func TestErasureLastSharedKeyOwnerRemovesPersonalRows(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	b := erasurefixture.SeedAccount(t, s)
	if _, err := s.pool.Exec(ctx, `UPDATE providers SET se_public_key=$1 WHERE id=$2`, a.SEKey, b.ProviderID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO provider_trust_reuse(se_pubkey,serial) VALUES($1,'shared-personal-serial')`, a.SEKey); err != nil {
		t.Fatal(err)
	}
	for _, acct := range []erasurefixture.Account{a, b} {
		now := time.Now().UTC()
		req := erasurefixture.PlanAndConfirm(t, s, acct, now, 0)
		res, err := s.ScrubAccount(ctx, req.ID, now)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("erased %s retains=%+v", acct.AccountID, res.Request.Summary.Applied.Retained)
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM provider_trust_reuse WHERE se_pubkey=$1`, a.SEKey).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("personal trust row retained after all owners erased")
	}
}

func TestErasureIncludesRetiredProviderEvidence(t *testing.T) {
	ctx := context.Background()
	s := testPostgresStore(t)
	a := erasurefixture.SeedAccount(t, s)
	if err := s.OpenProviderSession(ctx, a.ProviderID, "retired-serial", a.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO app_attest_evidence(id,session_id,key_id,received_at,action,sha256,context) VALUES('review-ev',$1,'review-kid',NOW(),'attestation','abc','{"boot_time":"retired-personal-marker"}')`, a.ProviderID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.pool.Exec(ctx, `INSERT INTO app_attest_evidence_blobs(evidence_id,proof_field,proof) VALUES('review-ev','proof','retired-proof-marker'::bytea)`); err != nil {
		t.Fatal(err)
	}
	if n, err := s.DeleteProvidersBySerial(ctx, a.AccountID, a.ProviderID); err != nil || n != 1 {
		t.Fatalf("remove provider=%d %v", n, err)
	}
	now := time.Now().UTC()
	req := erasurefixture.PlanAndConfirm(t, s, a, now, 0)
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	var n int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM app_attest_evidence_blobs WHERE evidence_id='review-ev'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("retired provider's personal App Attest proof survived erasure")
	}
}
