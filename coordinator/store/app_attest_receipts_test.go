package store

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestAppAttestReceiptVersionsAndLeasePostgres(t *testing.T) {
	s := testPostgresStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	r := AppAttestReceipt{ID: "initial", KeyID: "key", EvidenceID: "evidence", ReceivedAt: now, Outcome: "verified", Body: []byte{0, 1, 2}, Context: json.RawMessage(`{}`), Details: json.RawMessage(`{}`), NextAt: now.Add(-time.Second), ExpiresAt: now.Add(time.Hour)}
	if err := s.SaveAppAttestReceiptRefresh(ctx, r); err != nil {
		t.Fatal(err)
	}
	first, err := s.ClaimAppAttestReceipt(ctx, now)
	if err != nil || first == nil || string(first.Body) != string(r.Body) {
		t.Fatalf("claim %+v %v", first, err)
	}
	if second, err := s.ClaimAppAttestReceipt(ctx, now); err != nil || second != nil {
		t.Fatalf("double lease %+v %v", second, err)
	}
	failed := r
	failed.ID = "failed"
	failed.ParentID = r.ID
	failed.Outcome = "http_error"
	failed.HTTPStatus = 429
	failed.Body = nil
	failed.ResponseBody = []byte("rate limited")
	failed.NextAt = now.Add(time.Hour)
	if err = s.SaveAppAttestReceiptRefresh(ctx, failed); err != nil {
		t.Fatal(err)
	}
	var current string
	if err = s.pool.QueryRow(ctx, `SELECT receipt_id FROM app_attest_receipt_jobs WHERE key_id='key'`).Scan(&current); err != nil || current != "initial" {
		t.Fatal("failed renewal replaced usable receipt")
	}
	refreshed := r
	refreshed.ID = "refreshed"
	refreshed.ParentID = r.ID
	refreshed.Body = []byte{3, 4, 5}
	refreshed.NextAt = now.Add(30 * time.Minute)
	if err = s.SaveAppAttestReceiptRefresh(ctx, refreshed); err != nil {
		t.Fatal(err)
	}
	if err = s.pool.QueryRow(ctx, `SELECT receipt_id FROM app_attest_receipt_jobs WHERE key_id='key'`).Scan(&current); err != nil || current != "refreshed" {
		t.Fatal("new verified receipt not selected")
	}
	var count int
	if err = s.pool.QueryRow(ctx, `SELECT COUNT(*) FROM app_attest_receipt_blobs`).Scan(&count); err != nil || count != 3 {
		t.Fatal("receipt history was discarded")
	}
}
