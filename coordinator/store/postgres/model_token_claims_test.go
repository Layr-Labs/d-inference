package postgres

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestModelTokenPromotionSignupCutoffUsesPersistedCreationTime(t *testing.T) {
	for name, s := range map[string]store.Store{"postgres": testPostgresStore(t)} {
		t.Run(name, func(t *testing.T) {
			b, _ := store.As[store.ModelTokenPromotionStore](s)
			cutoff := time.Date(2026, 9, 19, 7, 0, 0, 0, time.UTC)
			now := cutoff.Add(12 * time.Hour)
			p := store.ModelTokenPromotion{ModelID: "eligibility", Tokens: 150_000_000, ClaimStartsAt: cutoff.Add(-24 * time.Hour), ClaimEndsAt: promotionClaimEnd(cutoff.Add(24 * time.Hour)), SignupCutoffAt: cutoff, MaxClaims: 250, Enabled: true}
			if err := b.PutModelTokenPromotion(p); err != nil {
				t.Fatal(err)
			}
			for _, tc := range []struct {
				id       string
				created  time.Time
				eligible bool
			}{{"old", cutoff.Add(-48 * time.Hour), true}, {"last_today", cutoff.Add(-time.Microsecond), true}, {"tomorrow", cutoff, false}} {
				if err := s.CreateUser(&store.User{AccountID: tc.id, PrivyUserID: "did:privy:" + tc.id}); err != nil {
					t.Fatal(err)
				}
				switch backend := s.(type) {

				case *PostgresStore:
					if _, err := backend.pool.Exec(context.Background(), `UPDATE users SET created_at=$2 WHERE account_id=$1`, tc.id, tc.created); err != nil {
						t.Fatal(err)
					}
				}
				_, err := b.ClaimModelTokenPromotion(tc.id, p.ModelID, now)
				if tc.eligible && err != nil {
					t.Fatal(tc.id, err)
				}
				if !tc.eligible && !errors.Is(err, store.ErrPromotionIneligible) {
					t.Fatalf("%s eligibility error %v", tc.id, err)
				}
			}
			promotions, _ := b.ListModelTokenPromotions()
			if promotions[0].ClaimedCount != 2 {
				t.Fatal("ineligible claim consumed slot")
			}
		})
	}
}
