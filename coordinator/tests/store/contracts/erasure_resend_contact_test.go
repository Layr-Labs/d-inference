package store_test

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/erasurefixture"
)

func TestErasureRetainsResendContactPrivatelyOnce(t *testing.T) {
	for name, s := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for _, email := range []string{" Resend-Erasure@Example.com ", "", "   "} {
				ctx := context.Background()
				a := erasurefixture.Account{AccountID: erasurefixture.UniqueID("resend"), PrivyID: erasurefixture.UniqueID("privy-resend"), Email: email}
				if err := s.CreateUser(&store.User{AccountID: a.AccountID, PrivyUserID: a.PrivyID, Email: email}); err != nil {
					t.Fatal(err)
				}
				now := time.Now().UTC()
				req := erasurefixture.PlanAndConfirm(t, s, a, now, time.Hour)
				_, pending, err := s.GetAccountErasure(ctx, a.AccountID)
				if err != nil || len(pending) != 0 {
					t.Fatalf("unexpected pre-scrub obligation: %v", err)
				}
				if _, err := s.ScrubAccount(ctx, req.ID, now.Add(time.Hour)); err != nil {
					t.Fatal(err)
				}
				if _, err := s.ScrubAccount(ctx, req.ID, now.Add(time.Hour)); !errors.Is(err, store.ErrErasureConflict) {
					t.Fatalf("second scrub: %v", err)
				}
				status, outbox, err := s.GetAccountErasure(ctx, a.AccountID)
				if err != nil {
					t.Fatal(err)
				}
				count := 0
				for _, item := range outbox {
					if item.Target != store.ErasureTargetResendContact {
						continue
					}
					count++
					if item.ExternalID != strings.ToLower(strings.TrimSpace(email)) || !item.HasExternalID || item.State != store.ErasureOutboxPending {
						t.Fatal("Resend obligation lost its private normalized contact or delivery state")
					}
				}
				want := 0
				if strings.TrimSpace(email) != "" {
					want = 1
				}
				if count != want || len(outbox) != want+1 {
					t.Fatalf("Resend rows = %d, total = %d; want %d and %d", count, len(outbox), want, want+1)
				}
				raw, err := json.Marshal(struct {
					Request *store.ErasureRequest
					Outbox  []store.ErasureOutboxItem
				}{status, outbox})
				if err != nil {
					t.Fatal(err)
				}
				if strings.Contains(strings.ToLower(string(raw)), "resend-erasure@example.com") || strings.Contains(string(raw), `"external_id":`) {
					t.Fatal("public erasure status leaked the contact")
				}
				plan, err := s.PlanAccountErasure(ctx, a.AccountID, nil)
				if err != nil || plan.Email != "" {
					t.Fatalf("users email not scrubbed: %v", err)
				}
			}
		})
	}
}
