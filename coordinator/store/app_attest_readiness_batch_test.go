package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"
)

func TestAppAttestReadinessBatchKnownCredentialsAndLatestVerifiedReceipt(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			keys, _ := As[AppAttestShadowStore](backend)
			archive, _ := As[AppAttestArchiveStore](backend)
			readiness, _ := As[AppAttestReadinessStore](backend)
			batch, ok := As[AppAttestReadinessBatchStore](NewCached(backend, DefaultCacheConfig()))
			if !ok {
				t.Fatal("batch readiness hidden by decorator")
			}
			for _, key := range []string{"good", "revoked", "no-receipt", "historical-only"} {
				if _, err := keys.InsertAppAttestShadowKey(ctx, AppAttestShadowKey{KeyID: key, AccountID: "owner"}); err != nil {
					t.Fatal(err)
				}
			}
			now := time.Now().UTC().Truncate(time.Microsecond)
			for _, receipt := range []AppAttestReceipt{
				{ID: "old", KeyID: "good", Outcome: "verified", ReceivedAt: now.Add(-time.Hour)},
				{ID: "current-a", KeyID: "good", Outcome: "verified", ReceivedAt: now},
				{ID: "current-b", KeyID: "good", Outcome: "verified", ReceivedAt: now},
				{ID: "rejected-newer", KeyID: "good", Outcome: "receipt_creation_time", ReceivedAt: now.Add(time.Minute)},
				{ID: "historic", KeyID: "historical-only", Outcome: "renewal_required", ReceivedAt: now},
			} {
				receipt.EvidenceID = "evidence-" + receipt.ID
				receipt.ExpiresAt, receipt.NextAt = now.Add(time.Hour), now.Add(30*time.Minute)
				receipt.Context = json.RawMessage(`{}`)
				receipt.Details = json.RawMessage(`{"type":"RECEIPT","risk_metric":1}`)
				receipt.Body = []byte("private receipt bytes")
				if err := archive.BeginAppAttestEvidence(ctx, AppAttestEvidence{ID: receipt.EvidenceID, KeyID: receipt.KeyID, SessionID: "session", ReceivedAt: now, Action: "attestation", Context: json.RawMessage(`{}`)}); err != nil {
					t.Fatal(err)
				}
				if outcome, err := archive.CompleteAppAttestEvidence(ctx, receipt.EvidenceID, AppAttestDecision{Outcome: "verified", Receipt: &receipt}); err != nil || outcome != "verified" {
					t.Fatalf("receipt setup: %s %v", outcome, err)
				}
			}
			if changed, err := readiness.RevokeAppAttestKey(ctx, "revoked", "owner", "compromised"); err != nil || !changed {
				t.Fatalf("revocation: %v", err)
			}
			result, err := batch.GetAppAttestReadinessBatch(ctx, []string{"good", "good", "revoked", "no-receipt", "historical-only", "unknown", ""})
			if err != nil || len(result) != 4 {
				t.Fatalf("known credential projection: %+v %v", result, err)
			}
			if _, known := result["unknown"]; known {
				t.Fatal("unknown credential became known unrevoked")
			}
			good := result["good"]
			if good.Revoked || good.Receipt == nil || good.Receipt.ID != "current-b" || good.Receipt.KeyID != "good" || !good.Receipt.ExpiresAt.Equal(now.Add(time.Hour)) || len(good.Receipt.Body) != 0 {
				t.Fatalf("latest verified metadata: %+v", good)
			}
			if !result["revoked"].Revoked || result["no-receipt"].Receipt != nil || result["historical-only"].Receipt != nil {
				t.Fatalf("negative or incomplete readiness became usable: %+v", result)
			}
			// A consumer cannot mutate cached receipt evidence through the result.
			good.Receipt.Details[0] = '!'
			again, err := batch.GetAppAttestReadinessBatch(ctx, []string{"good"})
			if err != nil || again["good"].Receipt == nil || !json.Valid(again["good"].Receipt.Details) {
				t.Fatalf("readiness escaped private storage: %v", err)
			}
		})
	}
}

func TestAppAttestReadinessBatchBoundsAndCancellation(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			batch, _ := As[AppAttestReadinessBatchStore](backend)
			ctx := context.Background()
			keys := make([]string, AppAttestReadinessBatchLimit+1)
			for i := range keys {
				keys[i] = fmt.Sprintf("key-%d", i)
			}
			if got, err := batch.GetAppAttestReadinessBatch(ctx, keys); err == nil || got != nil {
				t.Fatal("oversized batch accepted or returned partial authority")
			}
			if got, err := batch.GetAppAttestReadinessBatch(ctx, keys[:AppAttestReadinessBatchLimit]); err != nil || len(got) != 0 {
				t.Fatalf("bounded unknown credentials: %+v %v", got, err)
			}
			if got, err := batch.GetAppAttestReadinessBatch(ctx, nil); err != nil || len(got) != 0 {
				t.Fatalf("empty batch: %+v %v", got, err)
			}
			cancelled, cancel := context.WithCancel(ctx)
			cancel()
			if got, err := batch.GetAppAttestReadinessBatch(cancelled, []string{"key"}); !errors.Is(err, context.Canceled) || got != nil {
				t.Fatalf("cancelled batch produced authority: %+v %v", got, err)
			}
		})
	}
}
